from __future__ import annotations

import asyncio
import json
import re
import threading
import uuid
from collections import Counter, deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.train_random_forest import (
    DEFAULT_MODEL_PATH,
    build_feature_vector_from_raw_values,
    load_model,
    predict_label,
    save_model,
    train_model,
)
from postchair_ble import (
    CHARACTERISTIC_UUID,
    DEVICE_NAME,
    FSRFrame,
    find_device_address,
    stream_fsr_notifications,
)

VERSION = "0.1.0"
DEFAULT_SETTINGS_PATH = Path("data/runtime-settings.json")
DEFAULT_MODEL_SELECTION_PATH = Path("data/model-selection.json")
DEFAULT_TRAINING_DATA_DIR = Path("data")
DEFAULT_THRESHOLD_SECONDS = 60

LABEL_METADATA: dict[int, dict[str, Any]] = {
    0: {"id": 0, "name": "離席", "severity": "neutral"},
    1: {"id": 1, "name": "良い姿勢", "severity": "positive"},
    2: {"id": 2, "name": "猫背", "severity": "warning"},
    3: {"id": 3, "name": "前傾姿勢", "severity": "warning"},
    4: {"id": 4, "name": "右足組み", "severity": "warning"},
    5: {"id": 5, "name": "左足組み", "severity": "warning"},
}
NOTIFICATION_WARNING_LABEL_IDS = tuple(
    label_id
    for label_id, metadata in LABEL_METADATA.items()
    if metadata.get("severity") == "warning"
)


def normalize_notification_label_ids(label_ids: list[int] | tuple[int, ...] | set[int]) -> list[int]:
    return sorted(
        {
            int(label_id)
            for label_id in label_ids
            if int(label_id) in LABEL_METADATA
            and LABEL_METADATA[int(label_id)].get("severity") == "warning"
        }
    )


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def isoformat_or_none(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def format_file_size(size_bytes: int) -> str:
    units = ["B", "KB", "MB", "GB"]
    value = float(size_bytes)
    unit = units[0]
    for candidate in units:
        unit = candidate
        if value < 1024 or candidate == units[-1]:
            break
        value /= 1024
    if unit == "B":
        return f"{int(value)} {unit}"
    return f"{value:.1f} {unit}"


def slugify_model_name(name: str) -> str:
    normalized = re.sub(r"[^0-9A-Za-z]+", "-", name.strip()).strip("-").lower()
    return normalized or "custom-model"


@dataclass(slots=True)
class NotificationSettings:
    enabled: bool = True
    threshold_seconds: int = DEFAULT_THRESHOLD_SECONDS
    enabled_label_ids: list[int] = field(default_factory=lambda: list(NOTIFICATION_WARNING_LABEL_IDS))
    focus_mode: str = "indicator_only"

    def to_dict(self) -> dict[str, Any]:
        return {
            "enabled": self.enabled,
            "threshold_seconds": self.threshold_seconds,
            "enabled_label_ids": normalize_notification_label_ids(self.enabled_label_ids),
            "focus_mode": self.focus_mode,
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> NotificationSettings:
        return cls(
            enabled=bool(payload.get("enabled", True)),
            threshold_seconds=max(10, int(payload.get("threshold_seconds", DEFAULT_THRESHOLD_SECONDS))),
            enabled_label_ids=normalize_notification_label_ids(
                payload.get("enabled_label_ids", list(NOTIFICATION_WARNING_LABEL_IDS))
            ),
            focus_mode=str(payload.get("focus_mode", "indicator_only")),
        )


@dataclass(slots=True)
class NotificationEvent:
    sequence: int = 0
    label_id: int | None = None
    triggered_at: datetime | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence,
            "label_id": self.label_id,
            "label": LABEL_METADATA.get(self.label_id) if self.label_id is not None else None,
            "triggered_at": isoformat_or_none(self.triggered_at),
        }


@dataclass(slots=True)
class NotificationDebugState:
    observation_count: int = 0
    window_seconds: int = 0
    window_span_seconds: float = 0.0
    counts_by_label_id: dict[int, int] = field(default_factory=dict)
    qualifying_label_ids: list[int] = field(default_factory=list)
    active_notification_label_ids: list[int] = field(default_factory=list)
    last_evaluated_label_id: int | None = None
    blocked_reason: str = "idle"

    def to_dict(self) -> dict[str, Any]:
        return {
            "observation_count": self.observation_count,
            "window_seconds": self.window_seconds,
            "window_span_seconds": round(self.window_span_seconds, 3),
            "counts_by_label_id": self.counts_by_label_id,
            "qualifying_label_ids": self.qualifying_label_ids,
            "active_notification_label_ids": self.active_notification_label_ids,
            "last_evaluated_label_id": self.last_evaluated_label_id,
            "blocked_reason": self.blocked_reason,
        }


@dataclass(slots=True)
class NotificationObservation:
    label_id: int | None
    observed_at: datetime


@dataclass(slots=True)
class NotificationTracker:
    observations: deque[NotificationObservation] = field(default_factory=deque)
    active_notifications: set[int] = field(default_factory=set)
    event: NotificationEvent = field(default_factory=NotificationEvent)
    debug_state: NotificationDebugState = field(default_factory=NotificationDebugState)
    history_started_at: datetime | None = None

    def reset(self) -> None:
        self.observations.clear()
        self.active_notifications.clear()
        self.history_started_at = None
        self.debug_state = NotificationDebugState(blocked_reason="idle")

    def _prune_observations(self, observed_at: datetime, threshold_seconds: int) -> None:
        window_start = observed_at.timestamp() - threshold_seconds
        while self.observations and self.observations[0].observed_at.timestamp() < window_start:
            self.observations.popleft()

    def evaluate(
        self,
        label_id: int | None,
        observed_at: datetime,
        settings: NotificationSettings,
    ) -> NotificationEvent | None:
        if not settings.enabled:
            self.reset()
            self.debug_state.blocked_reason = "notifications_disabled"
            return None

        if self.history_started_at is None:
            self.history_started_at = observed_at

        self.observations.append(NotificationObservation(label_id=label_id, observed_at=observed_at))
        self._prune_observations(observed_at, settings.threshold_seconds)
        total_count = len(self.observations)
        counts = Counter(observation.label_id for observation in self.observations)
        counts_by_label_id = {
            int(candidate_label_id): count
            for candidate_label_id, count in counts.items()
            if candidate_label_id is not None
        }
        window_span_seconds = 0.0
        if self.observations:
            window_span_seconds = (
                observed_at - self.observations[0].observed_at
            ).total_seconds()
        elapsed_since_history_start = 0.0
        if self.history_started_at is not None:
            elapsed_since_history_start = (
                observed_at - self.history_started_at
            ).total_seconds()
        self.debug_state = NotificationDebugState(
            observation_count=total_count,
            window_seconds=settings.threshold_seconds,
            window_span_seconds=window_span_seconds,
            counts_by_label_id=counts_by_label_id,
            active_notification_label_ids=sorted(self.active_notifications),
            last_evaluated_label_id=label_id,
            blocked_reason="evaluating",
        )
        if total_count == 0:
            self.debug_state.blocked_reason = "no_observations"
            return None
        if elapsed_since_history_start < settings.threshold_seconds:
            self.debug_state.blocked_reason = "window_not_filled"
            return None

        qualifying_label_ids = [
            candidate_label_id
            for candidate_label_id in settings.enabled_label_ids
            if counts.get(candidate_label_id, 0) / total_count >= 0.8
        ]
        self.debug_state.qualifying_label_ids = qualifying_label_ids

        active_now = set(qualifying_label_ids)
        self.active_notifications.intersection_update(active_now)
        self.debug_state.active_notification_label_ids = sorted(self.active_notifications)
        if not qualifying_label_ids:
            self.debug_state.blocked_reason = "ratio_below_threshold"
            return None

        if label_id in qualifying_label_ids:
            selected_label_id = label_id
        else:
            selected_label_id = qualifying_label_ids[0]

        if selected_label_id in self.active_notifications:
            self.debug_state.blocked_reason = "already_notified"
            return None

        self.event.sequence += 1
        self.event.label_id = selected_label_id
        self.event.triggered_at = observed_at
        self.active_notifications.add(selected_label_id)
        self.debug_state.active_notification_label_ids = sorted(self.active_notifications)
        self.debug_state.blocked_reason = "triggered"
        return self.event


@dataclass(slots=True)
class MonitoringSnapshot:
    active: bool = False
    connection_state: str = "stopped"
    device_name: str = DEVICE_NAME
    device_address: str | None = None
    model_loaded: bool = False
    latest_frame: dict[str, Any] | None = None
    latest_label_id: int | None = None
    latest_label_metadata: dict[str, Any] | None = None
    last_error: str | None = None
    started_at: datetime | None = None
    last_frame_at: datetime | None = None
    notification_event: NotificationEvent = field(default_factory=NotificationEvent)
    notification_debug: NotificationDebugState = field(default_factory=NotificationDebugState)
    training_session: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "active": self.active,
            "connection_state": self.connection_state,
            "device_name": self.device_name,
            "device_address": self.device_address,
            "model_loaded": self.model_loaded,
            "latest_frame": self.latest_frame,
            "latest_label_id": self.latest_label_id,
            "latest_label_metadata": self.latest_label_metadata,
            "last_error": self.last_error,
            "started_at": isoformat_or_none(self.started_at),
            "last_frame_at": isoformat_or_none(self.last_frame_at),
            "notification_event": self.notification_event.to_dict(),
            "notification_debug": self.notification_debug.to_dict(),
            "training_session": self.training_session,
        }


@dataclass(slots=True)
class TrainingSessionState:
    active_label_id: int | None = None
    rows: list[dict[str, Any]] = field(default_factory=list)
    samples_by_label_id: dict[int, int] = field(default_factory=dict)
    started_at: datetime | None = None
    last_recorded_at: datetime | None = None
    last_recorded_frame_timestamp: str | None = None
    last_training_error: str | None = None

    def reset(self) -> None:
        self.active_label_id = None
        self.rows.clear()
        self.samples_by_label_id.clear()
        self.started_at = None
        self.last_recorded_at = None
        self.last_recorded_frame_timestamp = None
        self.last_training_error = None

    @property
    def total_samples(self) -> int:
        return len(self.rows)

    def to_dict(self) -> dict[str, Any]:
        return {
            "active_label_id": self.active_label_id,
            "active_label": LABEL_METADATA.get(self.active_label_id) if self.active_label_id is not None else None,
            "samples_by_label_id": {str(key): value for key, value in sorted(self.samples_by_label_id.items())},
            "total_samples": self.total_samples,
            "started_at": isoformat_or_none(self.started_at),
            "last_recorded_at": isoformat_or_none(self.last_recorded_at),
            "last_training_error": self.last_training_error,
        }


class RuntimeSettingsStore:
    def __init__(self, path: Path = DEFAULT_SETTINGS_PATH) -> None:
        self._path = path

    def load(self) -> NotificationSettings:
        if not self._path.exists():
            settings = NotificationSettings()
            self.save(settings)
            return settings

        raw_text = self._path.read_text(encoding="utf-8")
        payload = json.loads(raw_text)
        if not isinstance(payload, dict):
            raise ValueError(f"Settings file {self._path} must contain a JSON object")
        settings = NotificationSettings.from_dict(payload)
        if payload != settings.to_dict():
            self.save(settings)
        return settings

    def save(self, settings: NotificationSettings) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(
            json.dumps(settings.to_dict(), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )


class ModelSelectionStore:
    def __init__(self, path: Path = DEFAULT_MODEL_SELECTION_PATH) -> None:
        self._path = path

    def load(self) -> str | None:
        if not self._path.exists():
            return None
        payload = json.loads(self._path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"Model selection file {self._path} must contain a JSON object")
        selected_model = payload.get("selected_model")
        return str(selected_model) if selected_model else None

    def save(self, filename: str) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(
            json.dumps({"selected_model": filename}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )


class PostchairRuntimeService:
    def __init__(
        self,
        *,
        settings_store: RuntimeSettingsStore | None = None,
        model_selection_store: ModelSelectionStore | None = None,
        model_path: Path = DEFAULT_MODEL_PATH,
        model_directory: Path | None = None,
        training_data_directory: Path = DEFAULT_TRAINING_DATA_DIR,
    ) -> None:
        self._lock = threading.RLock()
        self._settings_store = settings_store or RuntimeSettingsStore()
        self._model_selection_store = model_selection_store or ModelSelectionStore()
        self._settings = self._settings_store.load()
        self._tracker = NotificationTracker()
        self._snapshot = MonitoringSnapshot()
        self._model_directory = model_directory or model_path.parent
        self._default_model_path = model_path
        self._training_data_directory = training_data_directory
        self._model_path = model_path
        self._model = None
        self._training_session = TrainingSessionState()
        self._monitor_thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._loop_ready = threading.Event()

        selected_filename = self._model_selection_store.load() or model_path.name
        try:
            self._load_selected_model(selected_filename)
        except Exception:
            self._snapshot.model_loaded = False
            self._snapshot.last_error = None
            if model_path.exists():
                self._load_selected_model(model_path.name)

    def health(self) -> dict[str, Any]:
        return {"ok": True, "version": VERSION}

    def backend_status(self) -> dict[str, Any]:
        with self._lock:
            return {
                "running": True,
                "version": VERSION,
                "model_loaded": self._snapshot.model_loaded,
                "connection_state": self._snapshot.connection_state,
                "last_error": self._snapshot.last_error,
                "current_model": self._model_path.name if self._model_path else None,
            }

    def notification_settings(self) -> dict[str, Any]:
        with self._lock:
            return self._settings.to_dict()

    def update_notification_settings(self, payload: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            merged = self._settings.to_dict()
            merged.update(payload)
            self._settings = NotificationSettings.from_dict(merged)
            self._settings_store.save(self._settings)
            self._tracker.reset()
            return self._settings.to_dict()

    def model_catalog(self) -> dict[str, Any]:
        with self._lock:
            current_filename = self._model_path.name if self._model_path else None
            return {
                "current_model_filename": current_filename,
                "current_model_display_name": current_filename or "未選択",
                "model_loaded": self._snapshot.model_loaded,
                "available_models": [
                    {
                        "filename": path.name,
                        "display_name": path.stem,
                        "file_size": format_file_size(path.stat().st_size),
                        "is_selected": path.name == current_filename,
                        "is_loaded": path.name == current_filename and self._snapshot.model_loaded,
                    }
                    for path in self._available_model_paths()
                ],
                "last_error": self._snapshot.last_error,
            }

    def select_model(self, filename: str) -> dict[str, Any]:
        with self._lock:
            try:
                self._load_selected_model(filename)
            except Exception as exc:
                self._snapshot.last_error = str(exc)
                raise
            return self.model_catalog()

    def set_training_recording_label(self, label_id: int | None) -> dict[str, Any]:
        with self._lock:
            if label_id is None:
                self._training_session.active_label_id = None
                self._snapshot.training_session = self._training_session.to_dict()
                return self._snapshot.training_session

            if label_id not in LABEL_METADATA:
                raise ValueError("Unsupported training label")

            active_label_id = self._training_session.active_label_id
            if active_label_id is not None and active_label_id != label_id:
                raise ValueError("Stop the current recording before selecting another posture")

            if self._training_session.started_at is None:
                self._training_session.started_at = utc_now()
            self._training_session.active_label_id = label_id
            self._training_session.last_training_error = None
            self._snapshot.training_session = self._training_session.to_dict()
            return self._snapshot.training_session

    def complete_training_session(self, model_name: str) -> dict[str, Any]:
        with self._lock:
            trimmed_name = model_name.strip()
            if not trimmed_name:
                raise ValueError("Model name is required")
            if self._training_session.active_label_id is not None:
                raise ValueError("Stop the current recording before training")
            if not self._training_session.rows:
                raise ValueError("No training samples have been recorded")

            slug = slugify_model_name(trimmed_name)
            model_path = self._model_directory / f"{slug}.joblib"
            if model_path.exists():
                raise FileExistsError(f"Model '{model_path.name}' already exists")

            try:
                model, metrics = train_model(self._training_session.rows)
                saved_data_path = self._save_training_rows(slug, self._training_session.rows)
                saved_model_path = save_model(model, model_path)
                self._load_selected_model(saved_model_path.name)
                result = {
                    "model_name": trimmed_name,
                    "model_filename": saved_model_path.name,
                    "data_filename": saved_data_path.name,
                    "sample_count": len(self._training_session.rows),
                    "metrics": metrics,
                }
                self._training_session.reset()
                self._snapshot.training_session = self._training_session.to_dict()
                return {
                    "model_catalog": self.model_catalog(),
                    "training_result": result,
                }
            except Exception as exc:
                self._training_session.last_training_error = str(exc)
                self._snapshot.training_session = self._training_session.to_dict()
                raise

    def monitoring_state(self) -> dict[str, Any]:
        with self._lock:
            self._snapshot.training_session = self._training_session.to_dict()
            state = self._snapshot.to_dict()
            state["current_model"] = self._model_path.name if self._model_path else None
            return state

    def start_monitoring(
        self,
        *,
        address: str | None = None,
        device_name: str = DEVICE_NAME,
        scan_timeout: float = 5.0,
    ) -> dict[str, Any]:
        with self._lock:
            if self._snapshot.active:
                return self._snapshot.to_dict()

            self._snapshot.active = True
            self._snapshot.connection_state = "starting"
            self._snapshot.last_error = None
            self._snapshot.started_at = utc_now()
            self._stop_event.clear()
            self._loop_ready.clear()

            self._monitor_thread = threading.Thread(
                target=self._run_monitor_loop,
                kwargs={
                    "address": address,
                    "device_name": device_name,
                    "scan_timeout": scan_timeout,
                },
                daemon=True,
            )
            self._monitor_thread.start()
            return self._snapshot.to_dict()

    def stop_monitoring(self) -> dict[str, Any]:
        thread: threading.Thread | None
        with self._lock:
            self._stop_event.set()
            thread = self._monitor_thread
            self._snapshot.active = False
            self._snapshot.connection_state = "stopped"
            self._snapshot.device_address = None
            self._tracker.reset()
            self._snapshot.training_session = self._training_session.to_dict()
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)
        return self.monitoring_state()

    def ingest_frame(
        self,
        frame: FSRFrame,
        *,
        predicted_label: int | None = None,
    ) -> MonitoringSnapshot:
        with self._lock:
            label_id = predicted_label
            if label_id is None and self._model is not None:
                label_id = predict_label(
                    self._model,
                    raw_left_front=frame.left_foot,
                    raw_right_front=frame.right_foot,
                    raw_center=frame.center,
                    raw_back=frame.rear,
                )

            observed_at = frame.received_at
            self._snapshot.last_frame_at = observed_at
            self._snapshot.latest_frame = {
                "center": frame.center,
                "left_foot": frame.left_foot,
                "rear": frame.rear,
                "right_foot": frame.right_foot,
                "received_at": isoformat_or_none(observed_at),
            }
            self._snapshot.latest_label_id = label_id
            self._snapshot.latest_label_metadata = LABEL_METADATA.get(label_id)
            self._record_training_row_if_needed(frame, observed_at)
            event = self._tracker.evaluate(label_id, observed_at, self._settings)
            self._snapshot.notification_debug = NotificationDebugState(
                observation_count=self._tracker.debug_state.observation_count,
                window_seconds=self._tracker.debug_state.window_seconds,
                window_span_seconds=self._tracker.debug_state.window_span_seconds,
                counts_by_label_id=dict(self._tracker.debug_state.counts_by_label_id),
                qualifying_label_ids=list(self._tracker.debug_state.qualifying_label_ids),
                active_notification_label_ids=list(self._tracker.debug_state.active_notification_label_ids),
                last_evaluated_label_id=self._tracker.debug_state.last_evaluated_label_id,
                blocked_reason=self._tracker.debug_state.blocked_reason,
            )
            if event is not None:
                self._snapshot.notification_event = NotificationEvent(
                    sequence=event.sequence,
                    label_id=event.label_id,
                    triggered_at=event.triggered_at,
                )
            self._snapshot.training_session = self._training_session.to_dict()
            return self._snapshot

    def _available_model_paths(self) -> list[Path]:
        if not self._model_directory.exists():
            return []
        return sorted(
            path for path in self._model_directory.glob("*.joblib") if path.is_file()
        )

    def _resolve_model_path(self, filename: str) -> Path:
        path = (self._model_directory / filename).resolve()
        model_directory = self._model_directory.resolve()
        if model_directory not in path.parents and path != model_directory:
            raise ValueError("Invalid model path")
        if not path.exists() or not path.is_file():
            raise FileNotFoundError(f"Model '{filename}' was not found")
        return path

    def _load_selected_model(self, filename: str) -> None:
        model_path = self._resolve_model_path(filename)
        model = load_model(model_path)
        self._model = model
        self._model_path = model_path
        self._snapshot.model_loaded = True
        self._snapshot.last_error = None
        self._model_selection_store.save(model_path.name)

    def _record_training_row_if_needed(self, frame: FSRFrame, observed_at: datetime) -> None:
        active_label_id = self._training_session.active_label_id
        if active_label_id is None:
            return

        received_at = isoformat_or_none(observed_at)
        if not received_at:
            return
        if received_at == self._training_session.last_recorded_frame_timestamp:
            return

        features = build_feature_vector_from_raw_values(
            frame.left_foot,
            frame.right_foot,
            frame.center,
            frame.rear,
        )
        row = {
            "id": str(uuid.uuid4()),
            "created_at": received_at,
            "raw_left_front": frame.left_foot,
            "raw_right_front": frame.right_foot,
            "raw_center": frame.center,
            "raw_back": frame.rear,
            "norm_left_front": features[4],
            "norm_right_front": features[5],
            "norm_center": features[6],
            "norm_back": features[7],
            "label": active_label_id,
        }
        self._training_session.rows.append(row)
        self._training_session.samples_by_label_id[active_label_id] = (
            self._training_session.samples_by_label_id.get(active_label_id, 0) + 1
        )
        self._training_session.last_recorded_at = observed_at
        self._training_session.last_recorded_frame_timestamp = received_at

    def _save_training_rows(self, slug: str, rows: list[dict[str, Any]]) -> Path:
        timestamp = utc_now().strftime("%Y%m%d%H%M%S")
        output_path = self._training_data_directory / f"sensor-data-{timestamp}-{slug}.json"
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(
            json.dumps(rows, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        return output_path

    def _run_monitor_loop(
        self,
        *,
        address: str | None,
        device_name: str,
        scan_timeout: float,
    ) -> None:
        try:
            asyncio.run(
                self._monitor(address=address, device_name=device_name, scan_timeout=scan_timeout)
            )
        except Exception as exc:  # pragma: no cover
            with self._lock:
                self._snapshot.last_error = str(exc)
                self._snapshot.connection_state = "error"
                self._snapshot.active = False

    async def _monitor(
        self,
        *,
        address: str | None,
        device_name: str,
        scan_timeout: float,
    ) -> None:
        resolved_address = address or await find_device_address(
            device_name=device_name,
            scan_timeout=scan_timeout,
        )
        with self._lock:
            self._snapshot.connection_state = "connecting"
            self._snapshot.device_address = resolved_address

        def on_frame(frame: FSRFrame) -> None:
            with self._lock:
                if not self._snapshot.active:
                    return
                self._snapshot.connection_state = "connected"
            self.ingest_frame(frame)
            if self._stop_event.is_set():
                raise asyncio.CancelledError

        stream_task = asyncio.create_task(
            stream_fsr_notifications(
                resolved_address,
                characteristic_uuid=CHARACTERISTIC_UUID,
                on_frame=on_frame,
            )
        )
        stop_task = asyncio.create_task(self._wait_for_stop())
        done, pending = await asyncio.wait(
            {stream_task, stop_task},
            return_when=asyncio.FIRST_COMPLETED,
        )

        for task in pending:
            task.cancel()
        for task in done:
            try:
                await task
            except asyncio.CancelledError:
                pass
            except Exception as exc:
                with self._lock:
                    self._snapshot.last_error = str(exc)
                    self._snapshot.connection_state = "error"
                    self._snapshot.active = False
                raise

        with self._lock:
            if self._snapshot.connection_state != "error":
                self._snapshot.connection_state = "stopped"
            self._snapshot.active = False

    async def _wait_for_stop(self) -> None:
        while not self._stop_event.is_set():
            await asyncio.sleep(0.1)
