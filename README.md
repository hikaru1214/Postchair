# Postchair

Postchair は、ESP32 から BLE で送られてくる FSR センサ値を受信し、必要に応じて学習済み RandomForest モデルでリアルタイム分類する Python プロジェクトです。

## できること

- ESP32 から BLE 通知を受信する
- `data/sensor-data-*.json` を使って姿勢ラベル分類モデルを学習する
- 学習済みモデルを使って、BLE 受信値をリアルタイム分類する

## 前提

- Python 3.12 以上
- `uv` が使えること
- BLE 接続できる環境であること
- ESP32 側が `ESP32_SmartSensor` としてアドバタイズしていること

## セットアップ

依存関係は `uv` 経由で解決します。

```bash
uv sync
```

`uv` を使わず一時実行したい場合でも、基本は `uv run ...` を使う想定です。

## 学習データ

学習には `data/sensor-data-*.json` をすべて結合して使用します。  
説明変数は次の 8 列です。

- `raw_left_front`
- `raw_right_front`
- `raw_center`
- `raw_back`
- `norm_left_front`
- `norm_right_front`
- `norm_center`
- `norm_back`

目的変数は `label` です。

## モデル学習

学習済みモデルを作るコマンド:

```bash
uv run postchair-train
```

別名で保存したい場合:

```bash
uv run postchair-train --output-path models/random_forest_label_20260319.joblib
```

実行すると次を行います。

- `data/sensor-data-*.json` を読み込む
- RandomForestClassifier で学習する
- Accuracy と分類レポートを表示する
- 特徴量重要度を表示する
- 学習済みモデルを `models/random_forest_label.joblib` に保存する

## BLE 受信のみ

BLE で値を受信して、そのまま表示するコマンド:

```bash
uv run postchair-ble
```

BLE アドレスを直接指定したい場合:

```bash
uv run postchair-ble --address XX:XX:XX:XX:XX:XX
```

## BLE のリアルタイム分類

学習済みモデルを使って、BLE 受信値をリアルタイムで分類するコマンド:

```bash
uv run postchair-ble --model-path
```

`--model-path` を値なしで付けると、既定の `models/random_forest_label.joblib` を使います。  
別のモデルファイルを使いたい場合はパスを指定します。

```bash
uv run postchair-ble --model-path models/random_forest_label.joblib
```

BLE アドレス指定と組み合わせる場合:

```bash
uv run postchair-ble --address XX:XX:XX:XX:XX:XX --model-path
```

出力例:

```text
2026-03-19T03:30:00.123 center=3815 left_foot=4095 rear=1334 right_foot=4070 predicted_label=1
```

## 主要ファイル

- `postchair_ble.py`: BLE 受信とリアルタイム分類の CLI
- `app/train_random_forest.py`: 学習、モデル保存、推論補助
- `data/`: 学習用センサデータ
- `models/`: 学習済みモデル出力先
- `tests/`: ユニットテスト

## ローカルサーバー方式

macOS の Swift アプリは、Mac 内で起動している Python/FastAPI バックエンドに HTTP 接続します。  
接続先は `http://127.0.0.1:8000` 固定です。

### 起動手順

#### 1. 依存関係を入れる

```bash
uv sync
```

#### 2. 必要なら学習済みモデルを作る

`models/random_forest_label.joblib` がまだない場合は先に作成します。

```bash
uv run postchair-train
```

#### 3. Python バックエンドを手動で起動する場合

プロジェクトルートで次を実行します。

```bash
uv run uvicorn postchair_server:app --host 127.0.0.1 --port 8000
```

起動後の確認:

```bash
curl http://127.0.0.1:8000/health
```

`{"ok":true,...}` のような JSON が返れば正常です。

#### 4. Swift アプリから自動起動する場合

Xcode で `ui/Postchair.xcodeproj` を開き、対象 Scheme の `Run > Arguments > Environment Variables` に次を設定してください。

```text
POSTCHAIR_BACKEND_ROOT=/path/to/Postchair
```

必要なら Python 実行ファイルも明示します。

```text
POSTCHAIR_PYTHON_PATH=/path/to/Postchair/.venv/bin/python
```

その後、Xcode から macOS アプリを起動します。  
アプリは最初に `http://127.0.0.1:8000/health` を確認し、未起動なら内部で次のコマンド相当を実行します。

```bash
.venv/bin/python -m uvicorn postchair_server:app --host 127.0.0.1 --port 8000
```

`POSTCHAIR_BACKEND_ROOT` が未設定の場合は、現在の作業ディレクトリに `postchair_server.py` があるときだけ自動起動できます。

### よく使う起動パターン

手早く確認したい場合:

1. ターミナルで `uv run uvicorn postchair_server:app --host 127.0.0.1 --port 8000`
2. Xcode から Swift アプリを起動

普段の開発で自動起動したい場合:

1. Xcode Scheme に `POSTCHAIR_BACKEND_ROOT` を設定
2. Xcode から Swift アプリを起動

## テスト

テスト実行:

```bash
uv run python -m unittest tests/test_parser.py tests/test_train_random_forest.py tests/test_live_classification.py tests/test_runtime_service.py
```

## よくある確認ポイント

- `uv run postchair-train` を先に実行してモデルを作成したか
- Bluetooth 権限が OS 側で許可されているか
- ESP32 が起動してアドバタイズ中か
- デバイス名が `ESP32_SmartSensor` で合っているか

## 補足

現在の評価値は、全データを学習用とテスト用に分割して測った値です。  
人物単位での汎化性能を確認したい場合は、人物ごとに分離した評価を別途追加してください。
