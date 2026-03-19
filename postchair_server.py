from __future__ import annotations

import argparse
from collections.abc import Callable
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from fastapi import Body, FastAPI, HTTPException, Request
from pydantic import BaseModel

from app.runtime_service import PostchairRuntimeService

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8000


class TrainingRecordingRequest(BaseModel):
    label_id: int | None = None


class TrainingCompleteRequest(BaseModel):
    model_name: str


def create_app(
    service_factory: Callable[[], PostchairRuntimeService] = PostchairRuntimeService,
) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        service = service_factory()
        app.state.service = service
        try:
            yield
        finally:
            service.stop_monitoring()

    app = FastAPI(title="Postchair Local Backend", lifespan=lifespan)

    def service_from(request: Request) -> PostchairRuntimeService:
        return request.app.state.service

    @app.get("/health")
    async def health(request: Request) -> dict[str, Any]:
        return service_from(request).health()

    @app.get("/api/status")
    async def backend_status(request: Request) -> dict[str, Any]:
        return service_from(request).backend_status()

    @app.get("/api/monitoring")
    async def monitoring_state(request: Request) -> dict[str, Any]:
        return service_from(request).monitoring_state()

    @app.post("/api/monitoring/start")
    async def start_monitoring(
        request: Request,
        payload: dict[str, Any] = Body(default_factory=dict),
    ) -> dict[str, Any]:
        return service_from(request).start_monitoring(
            address=payload.get("address"),
            device_name=str(payload.get("device_name", "ESP32_SmartSensor")),
            scan_timeout=float(payload.get("scan_timeout", 5.0)),
        )

    @app.post("/api/monitoring/stop")
    async def stop_monitoring(
        request: Request,
        payload: dict[str, Any] = Body(default_factory=dict),
    ) -> dict[str, Any]:
        del payload
        return service_from(request).stop_monitoring()

    @app.get("/api/notifications")
    async def notification_settings(request: Request) -> dict[str, Any]:
        return service_from(request).notification_settings()

    @app.put("/api/notifications")
    async def update_notification_settings(
        request: Request,
        payload: dict[str, Any] = Body(default_factory=dict),
    ) -> dict[str, Any]:
        return service_from(request).update_notification_settings(payload)

    @app.get("/api/model")
    async def model_catalog(request: Request) -> dict[str, Any]:
        return service_from(request).model_catalog()

    @app.put("/api/model")
    async def select_model(
        request: Request,
        payload: dict[str, Any] = Body(default_factory=dict),
    ) -> dict[str, Any]:
        return service_from(request).select_model(str(payload.get("filename", "")))

    @app.post("/api/training-session/recording")
    async def update_training_recording(
        request: Request,
        payload: TrainingRecordingRequest,
    ) -> dict[str, Any]:
        try:
            return service_from(request).set_training_recording_label(payload.label_id)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/training-session/complete")
    async def complete_training_session(
        request: Request,
        payload: TrainingCompleteRequest,
    ) -> dict[str, Any]:
        try:
            return service_from(request).complete_training_session(payload.model_name)
        except FileExistsError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    return app


app = create_app()


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Postchair local FastAPI backend.")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    return parser


def main() -> None:
    args = build_arg_parser().parse_args()
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
