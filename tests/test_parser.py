from __future__ import annotations

import unittest
from datetime import datetime

from postchair_ble import FSRFrame, FrameParseError, parse_fsr_frame


class ParseFSRFrameTests(unittest.TestCase):
    def test_parses_string_payload(self) -> None:
        self.assertEqual(parse_fsr_frame("100,200,300,400"), (100, 200, 300, 400))

    def test_parses_bytes_payload_with_newline(self) -> None:
        self.assertEqual(parse_fsr_frame(b"100,200,300,400\n"), (100, 200, 300, 400))

    def test_rejects_empty_payload(self) -> None:
        with self.assertRaises(FrameParseError):
            parse_fsr_frame("")

    def test_rejects_wrong_number_of_values(self) -> None:
        with self.assertRaises(FrameParseError):
            parse_fsr_frame("100,200,300")

        with self.assertRaises(FrameParseError):
            parse_fsr_frame("100,200,300,400,500")

    def test_rejects_non_integer_values(self) -> None:
        with self.assertRaises(FrameParseError):
            parse_fsr_frame("100,foo,300,400")

    def test_frame_uses_named_positions(self) -> None:
        frame = FSRFrame(100, 200, 300, 400, received_at=datetime.now())

        self.assertEqual(frame.center, 100)
        self.assertEqual(frame.left_foot, 200)
        self.assertEqual(frame.rear, 300)
        self.assertEqual(frame.right_foot, 400)
        self.assertEqual(frame.values, (100, 200, 300, 400))


if __name__ == "__main__":
    unittest.main()
