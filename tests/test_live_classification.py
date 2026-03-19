from __future__ import annotations

import unittest
from datetime import datetime

from app.train_random_forest import (
    build_feature_vector_from_raw_values,
    load_training_rows,
    train_model,
)
from postchair_ble import FSRFrame


class LiveClassificationTests(unittest.TestCase):
    def test_build_feature_vector_matches_training_schema(self) -> None:
        feature_vector = build_feature_vector_from_raw_values(
            raw_left_front=300,
            raw_right_front=200,
            raw_center=400,
            raw_back=100,
        )

        self.assertEqual(len(feature_vector), 8)
        self.assertEqual(feature_vector[:4], [300.0, 200.0, 400.0, 100.0])
        self.assertAlmostEqual(sum(feature_vector[4:]), 1.0)

    def test_trained_model_can_classify_ble_frame(self) -> None:
        rows = load_training_rows()
        model, _ = train_model(rows)
        frame = FSRFrame(
            center=3815,
            left_foot=4095,
            rear=1334,
            right_foot=4070,
            received_at=datetime.now(),
        )

        feature_vector = build_feature_vector_from_raw_values(
            raw_left_front=frame.left_foot,
            raw_right_front=frame.right_foot,
            raw_center=frame.center,
            raw_back=frame.rear,
        )
        prediction = model.predict([feature_vector])

        self.assertEqual(len(prediction), 1)
        self.assertIsInstance(int(prediction[0]), int)


if __name__ == "__main__":
    unittest.main()
