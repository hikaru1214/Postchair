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
    def make_service(self, temp_dir: str) -> PostchairRuntimeService:
        return PostchairRuntimeService(
            settings_store=RuntimeSettingsStore(Path(temp_dir) / "settings.json"),
            model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
            model_path=Path(temp_dir) / "models" / "default.joblib",
            model_directory=Path(temp_dir) / "models",
        )

    def ingest_labels(
        self,
        service: PostchairRuntimeService,
        start: datetime,
        labels: list[int],
    ) -> None:
        for offset, label_id in enumerate(labels):
            service.ingest_frame(
                FSRFrame(
                    10 + offset,
                    20 + offset,
                    30 + offset,
                    40 + offset,
                    received_at=start + timedelta(seconds=offset),
                ),
                predicted_label=label_id,
            )

    def test_health_and_status_exist_before_monitoring(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)

            self.assertEqual(service.health()["ok"], True)
            status = service.backend_status()
            self.assertEqual(status["connection_state"], "stopped")
            self.assertEqual(status["running"], True)

    def test_notification_settings_persist(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            settings_path = Path(temp_dir) / "settings.json"
            service = self.make_service(temp_dir)
            payload = {
                "enabled": False,
                "threshold_seconds": 25,
                "enabled_label_ids": [2, 4],
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
            self.assertEqual(reloaded.notification_settings()["enabled_label_ids"], [2, 4])

    def test_notification_triggers_at_eighty_percent_with_full_window(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            service.update_notification_settings(
                NotificationSettings(
                    enabled=True,
                    threshold_seconds=10,
                    enabled_label_ids=[2, 3, 4, 5],
                ).to_dict()
            )

            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)
            self.ingest_labels(service, start, [2] * 11)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 1)
            self.assertEqual(service.monitoring_state()["notification_event"]["label_id"], 2)

    def test_notification_does_not_trigger_before_window_is_filled(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            service.update_notification_settings(
                NotificationSettings(
                    enabled=True,
                    threshold_seconds=10,
                    enabled_label_ids=[2, 3, 4, 5],
                ).to_dict()
            )

            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)
            self.ingest_labels(service, start, [2] * 10)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 0)

    def test_notification_does_not_trigger_at_seventy_nine_percent(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            service.update_notification_settings(
                NotificationSettings(
                    enabled=True,
                    threshold_seconds=10,
                    enabled_label_ids=[2, 3, 4, 5],
                ).to_dict()
            )

            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)
            self.ingest_labels(service, start, [2] * 8 + [1, 1, 1])
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 0)

    def test_notification_does_not_trigger_for_mixed_bad_postures(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            service.update_notification_settings(
                NotificationSettings(
                    enabled=True,
                    threshold_seconds=10,
                    enabled_label_ids=[2, 3, 4, 5],
                ).to_dict()
            )

            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)
            self.ingest_labels(service, start, [2, 3] * 5 + [2])
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 0)

    def test_notification_retriggers_after_ratio_drops_below_threshold(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            service.update_notification_settings(
                NotificationSettings(
                    enabled=True,
                    threshold_seconds=10,
                    enabled_label_ids=[2, 3, 4, 5],
                ).to_dict()
            )

            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)
            self.ingest_labels(service, start, [2] * 11)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 1)

            self.ingest_labels(service, start + timedelta(seconds=11), [1] * 11)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 1)

            self.ingest_labels(service, start + timedelta(seconds=22), [2] * 11)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 2)

    def test_notification_state_resets_when_settings_change(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            service.update_notification_settings(
                NotificationSettings(
                    enabled=True,
                    threshold_seconds=10,
                    enabled_label_ids=[2, 3, 4, 5],
                ).to_dict()
            )

            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)
            self.ingest_labels(service, start, [2] * 11)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 1)

            service.update_notification_settings({"enabled_label_ids": [3, 4, 5]})
            self.ingest_labels(service, start + timedelta(seconds=20), [2] * 11)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 1)

            service.update_notification_settings({"enabled_label_ids": [2, 3, 4, 5]})
            self.ingest_labels(service, start + timedelta(seconds=40), [2] * 11)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 2)

    def test_notification_state_resets_when_monitoring_stops(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            service.update_notification_settings(
                NotificationSettings(
                    enabled=True,
                    threshold_seconds=10,
                    enabled_label_ids=[2, 3, 4, 5],
                ).to_dict()
            )

            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)
            self.ingest_labels(service, start, [2] * 11)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 1)

            service.stop_monitoring()
            self.ingest_labels(service, start + timedelta(seconds=20), [2] * 11)
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
