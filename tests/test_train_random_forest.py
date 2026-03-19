from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import joblib

from app.train_random_forest import (
    FEATURE_COLUMNS,
    TARGET_COLUMN,
    build_dataset,
    load_training_rows,
    save_model,
    train_model,
)


class TrainRandomForestTests(unittest.TestCase):
    def test_load_training_rows_contains_required_columns(self) -> None:
        rows = load_training_rows(Path("data"))

        self.assertGreater(len(rows), 0)
        for column in FEATURE_COLUMNS + (TARGET_COLUMN,):
            self.assertIn(column, rows[0])

    def test_train_model_and_save_model(self) -> None:
        rows = load_training_rows(Path("data"))

        model, metrics = train_model(rows)

        self.assertIn("accuracy", metrics)
        self.assertEqual(len(metrics["feature_importances"]), len(FEATURE_COLUMNS))

        with tempfile.TemporaryDirectory() as temp_dir:
            model_path = save_model(model, Path(temp_dir) / "random_forest_label.joblib")
            self.assertTrue(model_path.exists())

            loaded_model = joblib.load(model_path)
            features, _ = build_dataset(rows[:3])
            predictions = loaded_model.predict(features)
            self.assertEqual(len(predictions), 3)


if __name__ == "__main__":
    unittest.main()
