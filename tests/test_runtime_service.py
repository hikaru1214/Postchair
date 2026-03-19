from __future__ import annotations

import json
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib import request

import joblib
from app.runtime_service import (
    ModelSelectionStore,
    NotificationSettings,
    PostchairRuntimeService,
    RuntimeSettingsStore,
)
from sklearn.ensemble import RandomForestClassifier
from postchair_ble import FSRFrame
from postchair_server import PostchairRequestHandler
from http.server import ThreadingHTTPServer


def write_model_file(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(RandomForestClassifier(), path)


class RuntimeServiceTests(unittest.TestCase):
    def test_health_and_status_exist_before_monitoring(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = PostchairRuntimeService(
                settings_store=RuntimeSettingsStore(Path(temp_dir) / "settings.json"),
                model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                model_path=Path(temp_dir) / "models" / "default.joblib",
                model_directory=Path(temp_dir) / "models",
            )

            self.assertEqual(service.health()["ok"], True)
            status = service.backend_status()
            self.assertEqual(status["connection_state"], "stopped")
            self.assertEqual(status["running"], True)

    def test_notification_settings_persist(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            settings_path = Path(temp_dir) / "settings.json"
            service = PostchairRuntimeService(
                settings_store=RuntimeSettingsStore(settings_path),
                model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                model_path=Path(temp_dir) / "models" / "default.joblib",
                model_directory=Path(temp_dir) / "models",
            )
            payload = {
                "enabled": False,
                "threshold_seconds": 25,
                "enabled_label_ids": [1, 3],
            }

            updated = service.update_notification_settings(payload)
            reloaded = PostchairRuntimeService(
                settings_store=RuntimeSettingsStore(settings_path),
                model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                model_path=Path(temp_dir) / "models" / "default.joblib",
                model_directory=Path(temp_dir) / "models",
            )

            self.assertEqual(updated["enabled"], False)
            self.assertEqual(reloaded.notification_settings()["threshold_seconds"], 25)
            self.assertEqual(reloaded.notification_settings()["enabled_label_ids"], [1, 3])

    def test_continuous_bad_posture_triggers_once_and_resets(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = PostchairRuntimeService(
                settings_store=RuntimeSettingsStore(Path(temp_dir) / "settings.json"),
                model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                model_path=Path(temp_dir) / "models" / "default.joblib",
                model_directory=Path(temp_dir) / "models",
            )
            service.update_notification_settings(
                NotificationSettings(
                    enabled=True,
                    threshold_seconds=10,
                    enabled_label_ids=[1, 2, 3],
                ).to_dict()
            )

            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)
            first = FSRFrame(10, 20, 30, 40, received_at=start)
            second = FSRFrame(11, 21, 31, 41, received_at=start + timedelta(seconds=11))
            third = FSRFrame(12, 22, 32, 42, received_at=start + timedelta(seconds=12))
            reset = FSRFrame(13, 23, 33, 43, received_at=start + timedelta(seconds=13))
            retrigger = FSRFrame(14, 24, 34, 44, received_at=start + timedelta(seconds=24))

            service.ingest_frame(first, predicted_label=1)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 0)

            service.ingest_frame(second, predicted_label=1)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 1)

            service.ingest_frame(third, predicted_label=1)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 1)

            service.ingest_frame(reset, predicted_label=0)
            service.ingest_frame(retrigger, predicted_label=1)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 1)

            service.ingest_frame(
                FSRFrame(15, 25, 35, 45, received_at=start + timedelta(seconds=35)),
                predicted_label=1,
            )
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 2)

    def test_model_catalog_and_selection(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            model_dir = Path(temp_dir) / "models"
            default_model = model_dir / "default.joblib"
            alt_model = model_dir / "alternate.joblib"
            write_model_file(default_model)
            write_model_file(alt_model)

            service = PostchairRuntimeService(
                settings_store=RuntimeSettingsStore(Path(temp_dir) / "settings.json"),
                model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                model_path=default_model,
                model_directory=model_dir,
            )

            catalog = service.model_catalog()
            self.assertEqual(catalog["current_model_filename"], "default.joblib")
            self.assertEqual(len(catalog["available_models"]), 2)

            updated = service.select_model("alternate.joblib")
            self.assertEqual(updated["current_model_filename"], "alternate.joblib")

            reloaded = PostchairRuntimeService(
                settings_store=RuntimeSettingsStore(Path(temp_dir) / "settings.json"),
                model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                model_path=default_model,
                model_directory=model_dir,
            )
            self.assertEqual(reloaded.model_catalog()["current_model_filename"], "alternate.joblib")


class RuntimeServerTests(unittest.TestCase):
    def test_http_endpoints_return_expected_shapes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            model_dir = Path(temp_dir) / "models"
            model_path = model_dir / "default.joblib"
            write_model_file(model_path)
            service = PostchairRuntimeService(
                settings_store=RuntimeSettingsStore(Path(temp_dir) / "settings.json"),
                model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                model_path=model_path,
                model_directory=model_dir,
            )
            handler = type(
                "BoundHandler",
                (PostchairRequestHandler,),
                {"service": service},
            )
            server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base_url = f"http://127.0.0.1:{server.server_port}"
                health = json.loads(request.urlopen(f"{base_url}/health").read().decode("utf-8"))
                status = json.loads(
                    request.urlopen(f"{base_url}/api/status").read().decode("utf-8")
                )
                model = json.loads(
                    request.urlopen(f"{base_url}/api/model").read().decode("utf-8")
                )

                self.assertEqual(health["ok"], True)
                self.assertIn("running", status)
                self.assertIn("available_models", model)

                req = request.Request(
                    f"{base_url}/api/notifications",
                    method="PUT",
                    headers={"Content-Type": "application/json"},
                    data=json.dumps({"threshold_seconds": 30}).encode("utf-8"),
                )
                settings = json.loads(request.urlopen(req).read().decode("utf-8"))
                self.assertEqual(settings["threshold_seconds"], 30)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2.0)


if __name__ == "__main__":
    unittest.main()
