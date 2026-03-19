from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import joblib
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report
from sklearn.model_selection import train_test_split

FEATURE_COLUMNS = (
    "raw_left_front",
    "raw_right_front",
    "raw_center",
    "raw_back",
    "norm_left_front",
    "norm_right_front",
    "norm_center",
    "norm_back",
)
TARGET_COLUMN = "label"
REQUIRED_COLUMNS = FEATURE_COLUMNS + (TARGET_COLUMN,)
DEFAULT_DATA_DIR = Path("data")
DEFAULT_MODEL_PATH = Path("models/random_forest_label.joblib")


def build_feature_vector_from_raw_values(
    raw_left_front: int | float,
    raw_right_front: int | float,
    raw_center: int | float,
    raw_back: int | float,
) -> list[float]:
    total = raw_left_front + raw_right_front + raw_center + raw_back
    if total == 0:
        norm_left_front = 0.0
        norm_right_front = 0.0
        norm_center = 0.0
        norm_back = 0.0
    else:
        norm_left_front = float(raw_left_front) / float(total)
        norm_right_front = float(raw_right_front) / float(total)
        norm_center = float(raw_center) / float(total)
        norm_back = float(raw_back) / float(total)

    return [
        float(raw_left_front),
        float(raw_right_front),
        float(raw_center),
        float(raw_back),
        norm_left_front,
        norm_right_front,
        norm_center,
        norm_back,
    ]


def load_training_rows(data_dir: Path = DEFAULT_DATA_DIR) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    json_paths = sorted(data_dir.glob("sensor-data-*.json"))
    if not json_paths:
        raise FileNotFoundError(f"No sensor data files were found in {data_dir}")

    for json_path in json_paths:
        file_rows = json.loads(json_path.read_text(encoding="utf-8"))
        if not isinstance(file_rows, list):
            raise ValueError(f"{json_path} does not contain a JSON array")

        for index, row in enumerate(file_rows):
            if not isinstance(row, dict):
                raise ValueError(f"{json_path} row {index} is not a JSON object")

            missing = [column for column in REQUIRED_COLUMNS if column not in row]
            if missing:
                missing_columns = ", ".join(missing)
                raise ValueError(
                    f"{json_path} row {index} is missing required columns: {missing_columns}"
                )
            rows.append(row)

    return rows


def build_dataset(rows: list[dict[str, Any]]) -> tuple[list[list[float]], list[int]]:
    features = [
        build_feature_vector_from_raw_values(
            row["raw_left_front"],
            row["raw_right_front"],
            row["raw_center"],
            row["raw_back"],
        )
        for row in rows
    ]
    labels = [int(row[TARGET_COLUMN]) for row in rows]
    return features, labels


def train_model(
    rows: list[dict[str, Any]],
    *,
    test_size: float = 0.2,
    random_state: int = 42,
    n_estimators: int = 200,
    n_jobs: int = -1,
) -> tuple[RandomForestClassifier, dict[str, Any]]:
    features, labels = build_dataset(rows)
    X_train, X_test, y_train, y_test = train_test_split(
        features,
        labels,
        test_size=test_size,
        random_state=random_state,
        stratify=labels,
    )

    model = RandomForestClassifier(
        n_estimators=n_estimators,
        random_state=random_state,
        n_jobs=n_jobs,
    )
    model.fit(X_train, y_train)

    predictions = model.predict(X_test)
    metrics = {
        "total_rows": len(rows),
        "train_rows": len(X_train),
        "test_rows": len(X_test),
        "accuracy": accuracy_score(y_test, predictions),
        "classification_report": classification_report(
            y_test,
            predictions,
            zero_division=0,
        ),
        "feature_importances": sorted(
            zip(FEATURE_COLUMNS, model.feature_importances_, strict=True),
            key=lambda item: item[1],
            reverse=True,
        ),
    }
    return model, metrics


def save_model(model: RandomForestClassifier, output_path: Path = DEFAULT_MODEL_PATH) -> Path:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, output_path)
    return output_path


def load_model(model_path: Path = DEFAULT_MODEL_PATH) -> RandomForestClassifier:
    model = joblib.load(model_path)
    if not isinstance(model, RandomForestClassifier):
        raise TypeError(f"{model_path} does not contain a RandomForestClassifier")
    return model


def predict_label(
    model: RandomForestClassifier,
    *,
    raw_left_front: int | float,
    raw_right_front: int | float,
    raw_center: int | float,
    raw_back: int | float,
) -> int:
    feature_vector = build_feature_vector_from_raw_values(
        raw_left_front,
        raw_right_front,
        raw_center,
        raw_back,
    )
    prediction = model.predict([feature_vector])
    return int(prediction[0])


def format_metrics(metrics: dict[str, Any]) -> str:
    importances = "\n".join(
        f"  - {feature}: {importance:.6f}"
        for feature, importance in metrics["feature_importances"]
    )
    return "\n".join(
        [
            f"Loaded rows: {metrics['total_rows']}",
            f"Train rows: {metrics['train_rows']}",
            f"Test rows: {metrics['test_rows']}",
            f"Accuracy: {metrics['accuracy']:.4f}",
            "Classification report:",
            str(metrics["classification_report"]).rstrip(),
            "Feature importances:",
            importances,
        ]
    )


def main() -> None:
    rows = load_training_rows()
    model, metrics = train_model(rows)
    output_path = save_model(model)
    print(format_metrics(metrics))
    print(f"Saved model: {output_path}")


if __name__ == "__main__":
    main()
