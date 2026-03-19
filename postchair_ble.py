from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

DEVICE_NAME = "ESP32_SmartSensor"
SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
CHARACTERISTIC_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8"
DEFAULT_MODEL_PATH = Path("models/random_forest_label.joblib")


class FrameParseError(ValueError):
    pass


@dataclass(slots=True)
class FSRFrame:
    center: int
    left_foot: int
    rear: int
    right_foot: int
    received_at: datetime

    @property
    def values(self) -> tuple[int, int, int, int]:
        return (self.center, self.left_foot, self.rear, self.right_foot)


def parse_fsr_frame(payload: bytes | str) -> tuple[int, int, int, int]:
    if isinstance(payload, bytes):
        text = payload.decode("utf-8", errors="strict")
    else:
        text = payload

    text = text.strip()
    if not text:
        raise FrameParseError("Empty payload")

    parts = text.split(",")
    if len(parts) != 4:
        raise FrameParseError(f"Expected 4 values, got {len(parts)}: {text!r}")

    try:
        return tuple(int(part) for part in parts)  # type: ignore[return-value]
    except ValueError as exc:
        raise FrameParseError(f"Payload contains non-integer values: {text!r}") from exc


async def find_device_address(
    device_name: str = DEVICE_NAME,
    scan_timeout: float = 5.0,
) -> str:
    from bleak import BleakScanner

    device = await BleakScanner.find_device_by_name(device_name, timeout=scan_timeout)
    if device is None:
        raise RuntimeError(
            f"BLE device {device_name!r} was not found. "
            "Power on the ESP32 and confirm it is advertising."
        )
    return device.address


async def stream_fsr_notifications(
    address: str,
    characteristic_uuid: str = CHARACTERISTIC_UUID,
    on_frame: Callable[[FSRFrame], None] | None = None,
) -> None:
    from bleak import BleakClient

    def notification_handler(_: Any, data: bytearray) -> None:
        values = parse_fsr_frame(bytes(data))
        frame = FSRFrame(*values, received_at=datetime.now())
        if on_frame is not None:
            on_frame(frame)

    async with BleakClient(address) as client:
        await client.start_notify(characteristic_uuid, notification_handler)
        print(f"Connected to {address}. Waiting for notifications...")
        try:
            while client.is_connected:
                await asyncio.sleep(1.0)
        finally:
            await client.stop_notify(characteristic_uuid)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Receive FSR data from the ESP32 BLE notifier.",
    )
    parser.add_argument(
        "--address",
        help="BLE address of the ESP32. If omitted, scan by advertised name.",
    )
    parser.add_argument(
        "--name",
        default=DEVICE_NAME,
        help=f"Advertised BLE name to scan for (default: {DEVICE_NAME}).",
    )
    parser.add_argument(
        "--scan-timeout",
        type=float,
        default=5.0,
        help="Seconds to wait when scanning by device name.",
    )
    parser.add_argument(
        "--model-path",
        type=Path,
        help=(
            "Path to a trained RandomForest model. "
            f"If provided without a value, defaults to {DEFAULT_MODEL_PATH}."
        ),
        nargs="?",
        const=DEFAULT_MODEL_PATH,
    )
    return parser


async def async_main() -> None:
    args = build_arg_parser().parse_args()
    address = args.address or await find_device_address(
        device_name=args.name,
        scan_timeout=args.scan_timeout,
    )
    model = None
    predict_frame_label: Callable[[FSRFrame], int] | None = None
    if args.model_path:
        from app.train_random_forest import load_model, predict_label

        model = load_model(args.model_path)

        def predict_frame_label(frame: FSRFrame) -> int:
            return predict_label(
                model,
                raw_left_front=frame.left_foot,
                raw_right_front=frame.right_foot,
                raw_center=frame.center,
                raw_back=frame.rear,
            )

    def print_frame(frame: FSRFrame) -> None:
        timestamp = frame.received_at.isoformat(timespec="milliseconds")
        message = (
            f"{timestamp} "
            f"center={frame.center} "
            f"left_foot={frame.left_foot} "
            f"rear={frame.rear} "
            f"right_foot={frame.right_foot}"
        )
        if predict_frame_label is not None:
            predicted_label = predict_frame_label(frame)
            message = f"{message} predicted_label={predicted_label}"
        print(message)

    await stream_fsr_notifications(address=address, on_frame=print_frame)


def main() -> None:
    asyncio.run(async_main())


if __name__ == "__main__":
    main()
