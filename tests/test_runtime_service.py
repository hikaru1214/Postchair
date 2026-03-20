from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import joblib
from fastapi.testclient import TestClient
from app.runtime_service import (
    ModelSelectionStore,
    NotificationSettings,
    PostchairRuntimeService,
    RuntimeSettingsStore,
)
from sklearn.ensemble import RandomForestClassifier
from postchair_ble import FSRFrame
from postchair_server import create_app


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
            training_data_directory=Path(temp_dir) / "data",
        )

    def ingest_labels(
        self,
        service: PostchairRuntimeService,
        start: datetime,
        labels: list[int],
        *,
        step_seconds: float = 1.0,
    ) -> None:
        for offset, label_id in enumerate(labels):
            service.ingest_frame(
                FSRFrame(
                    10 + offset,
                    20 + offset,
                    30 + offset,
                    40 + offset,
                    received_at=start + timedelta(seconds=offset * step_seconds),
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

    def test_notification_settings_filter_non_warning_labels_on_update(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)

            updated = service.update_notification_settings(
                {"enabled_label_ids": [0, 1, 2, 3, 99]}
            )

            self.assertEqual(updated["enabled_label_ids"], [2, 3])

    def test_notification_settings_filter_non_warning_labels_on_load(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            settings_path = Path(temp_dir) / "settings.json"
            settings_path.write_text(
                """
{
  "enabled": true,
  "threshold_seconds": 60,
  "enabled_label_ids": [0, 1, 2, 3],
  "focus_mode": "indicator_only"
}
""".strip()
                + "\n",
                encoding="utf-8",
            )

            service = self.make_service(temp_dir)

            self.assertEqual(service.notification_settings()["enabled_label_ids"], [2, 3])
            persisted = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertEqual(persisted["enabled_label_ids"], [2, 3])

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
            self.assertEqual(
                service.monitoring_state()["notification_debug"]["blocked_reason"],
                "window_not_filled",
            )

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
            self.assertEqual(
                service.monitoring_state()["notification_debug"]["blocked_reason"],
                "ratio_below_threshold",
            )

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
            self.assertEqual(
                service.monitoring_state()["notification_debug"]["blocked_reason"],
                "ratio_below_threshold",
            )

    def test_notification_debug_reports_triggered_state(self) -> None:
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
            debug = service.monitoring_state()["notification_debug"]
            self.assertEqual(debug["blocked_reason"], "triggered")
            self.assertEqual(debug["qualifying_label_ids"], [2])
            self.assertEqual(debug["counts_by_label_id"], {2: 11})

    def test_notification_triggers_with_dense_sampling_after_threshold_elapsed(self) -> None:
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
            self.ingest_labels(service, start, [3] * 101, step_seconds=0.1)
            state = service.monitoring_state()
            self.assertEqual(state["notification_event"]["sequence"], 1)
            self.assertEqual(state["notification_event"]["label_id"], 3)
            self.assertEqual(state["notification_debug"]["blocked_reason"], "triggered")

    def test_notification_waits_for_longer_threshold_before_triggering(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            service.update_notification_settings(
                NotificationSettings(
                    enabled=True,
                    threshold_seconds=180,
                    enabled_label_ids=[2, 3, 4, 5],
                ).to_dict()
            )

            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)
            self.ingest_labels(service, start, [3] * 180, step_seconds=1.0)
            self.assertEqual(service.monitoring_state()["notification_event"]["sequence"], 0)
            self.assertEqual(
                service.monitoring_state()["notification_debug"]["blocked_reason"],
                "window_not_filled",
            )

            service.ingest_frame(
                FSRFrame(100, 100, 100, 100, received_at=start + timedelta(seconds=180)),
                predicted_label=3,
            )
            state = service.monitoring_state()
            self.assertEqual(state["notification_event"]["sequence"], 1)
            self.assertEqual(state["notification_event"]["label_id"], 3)
            self.assertEqual(state["notification_debug"]["blocked_reason"], "triggered")

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

    def test_training_recording_requires_stop_before_switching_labels(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)

            state = service.set_training_recording_label(0)
            self.assertEqual(state["active_label_id"], 0)

            with self.assertRaises(ValueError):
                service.set_training_recording_label(2)

            state = service.set_training_recording_label(None)
            self.assertEqual(state["active_label_id"], None)

            state = service.set_training_recording_label(2)
            self.assertEqual(state["active_label_id"], 2)

    def test_training_recording_accepts_away_label_and_counts_samples(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            recorded_at = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)

            state = service.set_training_recording_label(0)
            self.assertEqual(state["active_label_id"], 0)

            service.ingest_frame(
                FSRFrame(10, 20, 30, 40, received_at=recorded_at),
                predicted_label=0,
            )
            service.set_training_recording_label(None)

            training = service.monitoring_state()["training_session"]
            self.assertEqual(training["total_samples"], 1)
            self.assertEqual(training["samples_by_label_id"], {"0": 1})

    def test_training_recording_collects_rows_only_while_active(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)

            service.set_training_recording_label(1)
            service.ingest_frame(
                FSRFrame(101, 202, 303, 404, received_at=start),
                predicted_label=1,
            )
            service.set_training_recording_label(None)
            service.ingest_frame(
                FSRFrame(111, 222, 333, 444, received_at=start + timedelta(seconds=1)),
                predicted_label=1,
            )

            training = service.monitoring_state()["training_session"]
            self.assertEqual(training["total_samples"], 1)
            self.assertEqual(training["samples_by_label_id"], {"1": 1})

    def test_training_completion_saves_data_and_model_and_selects_it(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)
            start = datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc)

            for label_id, offset in [(1, 0), (2, 10)]:
                service.set_training_recording_label(label_id)
                for step in range(10):
                    service.ingest_frame(
                        FSRFrame(
                            300 + label_id + step,
                            400 + label_id + step,
                            500 + label_id + step,
                            600 + label_id + step,
                            received_at=start + timedelta(seconds=offset + step),
                        ),
                        predicted_label=label_id,
                    )
                service.set_training_recording_label(None)

            result = service.complete_training_session("Session Model")
            catalog = result["model_catalog"]
            training_result = result["training_result"]

            self.assertEqual(catalog["current_model_filename"], "session-model.joblib")
            self.assertEqual(training_result["sample_count"], 20)
            self.assertTrue((Path(temp_dir) / "models" / "session-model.joblib").exists())
            self.assertTrue((Path(temp_dir) / "data" / training_result["data_filename"]).exists())
            self.assertEqual(service.monitoring_state()["training_session"]["total_samples"], 0)

    def test_training_completion_requires_samples_and_unique_model_name(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            write_model_file(Path(temp_dir) / "models" / "default.joblib")
            service = self.make_service(temp_dir)

            with self.assertRaises(ValueError):
                service.complete_training_session("  ")

            service.set_training_recording_label(1)
            service.ingest_frame(
                FSRFrame(
                    100,
                    200,
                    300,
                    400,
                    received_at=datetime(2026, 3, 19, 0, 0, tzinfo=timezone.utc),
                ),
                predicted_label=1,
            )
            service.set_training_recording_label(None)

            with self.assertRaises(ValueError):
                service.complete_training_session("single-class")


class RuntimeServerTests(unittest.TestCase):
    def test_http_endpoints_return_expected_shapes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            model_dir = Path(temp_dir) / "models"
            model_path = model_dir / "default.joblib"
            write_model_file(model_path)
            app = create_app(
                service_factory=lambda: PostchairRuntimeService(
                    settings_store=RuntimeSettingsStore(Path(temp_dir) / "settings.json"),
                    model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                    model_path=model_path,
                    model_directory=model_dir,
                )
            )

            with TestClient(app) as client:
                health = client.get("/health").json()
                status = client.get("/api/status").json()
                model = client.get("/api/model").json()

                self.assertEqual(health["ok"], True)
                self.assertIn("running", status)
                self.assertIn("available_models", model)

                settings = client.put(
                    "/api/notifications",
                    json={"threshold_seconds": 30},
                ).json()
                self.assertEqual(settings["threshold_seconds"], 30)

    def test_training_endpoints_follow_record_stop_train_flow(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            model_dir = Path(temp_dir) / "models"
            model_path = model_dir / "default.joblib"
            write_model_file(model_path)
            app = create_app(
                service_factory=lambda: PostchairRuntimeService(
                    settings_store=RuntimeSettingsStore(Path(temp_dir) / "settings.json"),
                    model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                    model_path=model_path,
                    model_directory=model_dir,
                    training_data_directory=Path(temp_dir) / "data",
                )
            )

            with TestClient(app) as client:
                response = client.post("/api/training-session/recording", json={"label_id": 1})
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json()["active_label_id"], 1)

                conflict = client.post("/api/training-session/recording", json={"label_id": 2})
                self.assertEqual(conflict.status_code, 400)

                stop = client.post("/api/training-session/recording", json={"label_id": None})
                self.assertEqual(stop.status_code, 200)
                self.assertEqual(stop.json()["active_label_id"], None)

    def test_lifespan_stops_monitoring_on_shutdown(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            model_dir = Path(temp_dir) / "models"
            model_path = model_dir / "default.joblib"
            write_model_file(model_path)

            class TrackingService(PostchairRuntimeService):
                def __init__(self) -> None:
                    super().__init__(
                        settings_store=RuntimeSettingsStore(Path(temp_dir) / "settings.json"),
                        model_selection_store=ModelSelectionStore(Path(temp_dir) / "model.json"),
                        model_path=model_path,
                        model_directory=model_dir,
                    )
                    self.stop_calls = 0

                def stop_monitoring(self) -> dict[str, object]:
                    self.stop_calls += 1
                    return super().stop_monitoring()

            holder: dict[str, TrackingService] = {}

            def service_factory() -> TrackingService:
                service = TrackingService()
                holder["service"] = service
                return service

            app = create_app(service_factory=service_factory)

            with TestClient(app) as client:
                response = client.get("/health")
                self.assertEqual(response.status_code, 200)

            self.assertEqual(holder["service"].stop_calls, 1)


if __name__ == "__main__":
    unittest.main()
