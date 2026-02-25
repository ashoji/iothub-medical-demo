# 実装プラン: Azure Functions IoT テレメトリ処理

## 全体スケジュール

| Phase | 内容 | 前提条件 |
|---|---|---|
| Phase 1 | ローカル開発環境・コード実装 | なし |
| Phase 2 | Azure リソース準備 | Azure サブスクリプション |
| Phase 3 | デプロイ・動作確認 | Phase 1, 2 完了 |
| Phase 4 | Logic Apps 連携 (メール通知) | Phase 3 完了 |

---

## Phase 1: ローカル開発環境・コード実装 ✅ 完了

### 1-1. フォルダ構成

```
functions-app-csharp/
├── ProcessTelemetry.cs      # EventHub Trigger 関数 (C# isolated worker)
├── Program.cs               # DI 設定 (HttpClientFactory, ApplicationInsights)
├── FunctionsApp.csproj      # プロジェクト定義 (NuGet パッケージ)
├── host.json                # Functions ホスト設定
├── local.settings.json      # ローカル開発用設定
├── Properties/
│   └── launchSettings.json  # デバッグ起動設定
└── README.md                # 詳細ドキュメント
```

### 1-2. 実装済みファイル

| ファイル | 内容 | ステータス |
|---|---|---|
| `ProcessTelemetry.cs` | EventHub トリガー関数、ステータス判定、Blob 出力、Logic Apps 通知 | ✅ |
| `Program.cs` | DI 設定 (HttpClientFactory, ApplicationInsights) | ✅ |
| `FunctionsApp.csproj` | NuGet パッケージ定義 | ✅ |
| `host.json` | EventHub バッチ設定 (maxEventBatchSize=64) | ✅ |
| `local.settings.json` | 接続文字列テンプレート | ✅ (値は Phase 2 で設定) |

### 1-3. function_app.py の関数構成

| 関数名 | 役割 |
|---|---|
| `ProcessTelemetry()` | エントリポイント: EventHub バッチ受信 → 処理ループ |
| `EvaluateStatus()` | クラウド側ステータス再判定 (閾値チェック) |
| Blob アップロード | /processed コンテナへ加工済み JSON 保存 |
| Logic Apps 通知 | critical 時の HTTP POST |

---

## Phase 2: Azure リソース準備

### 2-1. IoT Hub にコンシューマグループを追加

```bash
az iot hub consumer-group create \
  --hub-name <your-iothub-name> \
  --resource-group <your-resource-group> \
  --name functions-cg
```

### 2-2. 既存 Storage Account に `processed` コンテナを作成

```bash
az storage container create \
  --name processed \
  --account-name <your-storage-account> \
  --auth-mode login
```

### 2-3. Function App を Azure に作成 (Flex Consumption Plan)

```bash
# Functions 用 Storage Account (内部管理用)
az storage account create \
  --name stfuncmedical$(date +%s | tail -c 10) \
  --resource-group <your-resource-group> \
  --location japaneast \
  --sku Standard_LRS

# Function App (Flex Consumption)
az functionapp create \
  --name <your-function-app> \
  --resource-group <your-resource-group> \
  --storage-account <上で作成した Storage Account 名> \
  --flexconsumption-location japaneast \
  --runtime dotnet-isolated \
  --runtime-version 10.0 \
  --functions-version 4
```

### 2-4. Event Hub 互換エンドポイント接続文字列の取得

```bash
# Event Hub 互換エンドポイント接続文字列
az iot hub connection-string show \
  --hub-name <your-iothub-name> \
  --resource-group <your-resource-group> \
  --default-eventhub \
  --query connectionString -o tsv
```

### 2-5. Storage Account 接続文字列の取得

```bash
az storage account show-connection-string \
  --name <your-storage-account> \
  --resource-group <your-resource-group> \
  --query connectionString -o tsv
```

### 2-6. Function App のアプリ設定に環境変数を登録

```bash
FUNC_APP_NAME="<your-function-app>"
RG="<your-resource-group>"

az functionapp config appsettings set \
  --name $FUNC_APP_NAME \
  --resource-group $RG \
  --settings \
    "IoTHubEventHubConnectionString=<2-4 で取得した値>" \
    "IoTHubEventHubName=<your-iothub-name>" \
    "IoTHubConsumerGroup=functions-cg" \
    "ProcessedBlobConnectionString=<2-5 で取得した値>" \
    "ProcessedBlobContainerName=processed" \
    "LOGIC_APP_URL="
```

---

## Phase 3: デプロイ・動作確認

### 3-1. Azure Functions Core Tools でデプロイ

```bash
cd functions-app-csharp
func azure functionapp publish <your-function-app> --dotnet-isolated
```

### 3-2. デバイスシミュレータで動作確認

```bash
# 1台だけで確認
cd device-simulator
set -a && source ../.env && set +a
python3 device_simulator.py icu-device01 telemetry --interval 5000 --warning-rate 20 --critical-rate 10
```

### 3-3. 確認ポイント

| 確認項目 | 方法 |
|---|---|
| Functions が起動しているか | Azure Portal → Function App → 関数一覧 |
| テレメトリが処理されているか | Azure Portal → Function App → Monitor → ログ |
| /processed に JSON が出力されるか | Azure Portal → Storage Account → processed コンテナ |
| JSON の中身が正しいか | processed 内の JSON をダウンロードして確認 |
| critical ログが出ているか | Functions ログに `[CRITICAL]` が含まれるか |

### 3-4. トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| Functions が起動しない | 接続文字列の設定ミス | `az functionapp config appsettings list` で確認 |
| メッセージが受信されない | コンシューマグループ未作成 | `az iot hub consumer-group list` で確認 |
| Blob が出力されない | ProcessedBlobConnectionString 未設定 | アプリ設定を確認 |
| パーミッションエラー | Storage のアクセス権不足 | 接続文字列の権限を確認 |

---

## Phase 4: Logic Apps 連携 (メール通知)

### 4-1. Logic Apps 作成

```bash
# Logic Apps はポータル or Bicep で作成
# HTTP トリガー → Office 365 メール送信 のワークフロー
```

**Logic Apps フロー:**

```
HTTP Request トリガー (POST)
  ↓ JSON パース
  ↓ メール本文を構築
  ↓ Office 365 Outlook / SendGrid でメール送信
```

**メール本文テンプレート例:**

```
件名: [CRITICAL] 医療デバイス異常検知 - {deviceId}

本文:
デバイス {deviceId} で異常を検知しました。

■ 検知時刻: {timestamp}
■ 異常項目: {alerts}
■ 心拍数: {heartRate} bpm
■ 体温: {bodyTemperature} °C
■ SpO2: {spo2} %

直ちに確認してください。
```

### 4-2. Function App に Logic Apps URL を設定

```bash
az functionapp config appsettings set \
  --name <your-function-app> \
  --resource-group <your-resource-group> \
  --settings "LOGIC_APP_URL=<your-logic-app-url>"
```

### 4-3. Critical 通知テスト

```bash
# critical 100% でテスト
python3 device_simulator.py icu-device01 telemetry \
  --interval 10000 --warning-rate 0 --critical-rate 100
```

---

## ローカルデバッグ手順 (オプション)

Azure Functions Core Tools がインストール済みの場合:

```bash
# 1. local.settings.json に接続文字列を設定

# 2. ローカル起動
cd functions-app-csharp
dotnet build
func start

# 3. 別ターミナルでシミュレータ起動
cd device-simulator
set -a && source ../.env && set +a
python3 device_simulator.py icu-device01 telemetry
```

---

## コスト見積もり

| リソース | SKU | 概算月額 |
|---|---|---|
| IoT Hub | S1 | ~$25 |
| Storage Account (既存) | Standard_LRS | ~$1 以下 |
| Function App | Flex Consumption | ~$0 (デモ規模の無料枠内) |
| Logic Apps | Consumption | ~$0 (実行回数が少ないため) |
| **合計** | | **~$26/月** |

※ デモ終了後は `az group delete --name <your-resource-group> --yes` で全リソース削除

---

## 依存関係

```
device-simulator (既存)
    └─ IoT Hub (既存)
          ├─ メッセージルーティング → /telemetry (既存)
          └─ Event Hub 互換エンドポイント
                └─ functions-cg (新規)
                      └─ Azure Functions (Phase 1 で実装済み)
                            ├─ /processed (Phase 2 で作成)
                            └─ Logic Apps (Phase 4 で作成)
                                  └─ メール送信
```
