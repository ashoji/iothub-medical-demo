# Azure Functions - IoT テレメトリ処理バックエンド (C#)

IoT Hub から受信した医療デバイスのテレメトリデータを処理する Azure Functions アプリケーションです。

## 概要

```
IoT Hub (EventHub互換EP)
    │
    ▼
┌──────────────────────────────────┐
│  ProcessTelemetry (EventHub Trigger) │
│                                      │
│  1. JSON パース                      │
│  2. ステータス再判定                 │
│  3. 加工済み JSON → Blob Storage     │
│  4. critical → Logic Apps 通知       │
└──────────────────────────────────┘
    │                    │
    ▼                    ▼
Blob Storage         Logic Apps
(/processed)        (メール通知)
```

## 技術スタック

| 項目 | 値 |
|---|---|
| ランタイム | .NET 10.0 (isolated worker) |
| Azure Functions | v4 |
| SKU | Flex Consumption |
| トリガー | EventHub Trigger (IoT Hub 互換) |
| 出力先 | Azure Blob Storage (`processed` コンテナ) |
| 通知 | Logic Apps (HTTP POST) ※ critical 時のみ |

## プロジェクト構成

```
functions-app-csharp/
├── FunctionsApp.csproj    # プロジェクト定義 (NuGet パッケージ)
├── Program.cs             # エントリーポイント (DI 設定)
├── ProcessTelemetry.cs    # メイン関数 (EventHub Trigger)
├── Properties/
│   └── launchSettings.json # ローカルデバッグ設定
├── host.json              # Functions ホスト設定
├── local.settings.json    # ローカル実行用設定
└── README.md              # 本ファイル
```

## 処理フロー

### 1. EventHub Trigger でテレメトリ受信

IoT Hub の EventHub 互換エンドポイントからバッチでメッセージを受信します。

```csharp
[EventHubTrigger(
    eventHubName: "%IoTHubEventHubName%",
    Connection = "IoTHubEventHubConnectionString",
    ConsumerGroup = "%IoTHubConsumerGroup%",
    IsBatched = true)]
string[] messages
```

### 2. ステータス再判定 (EvaluateStatus)

デバイス側の `patientStatus` とは独立に、クラウド側でバイタルサインを再判定します。

| バイタル | warning 閾値 | critical 閾値 | チェック方向 |
|---|---|---|---|
| heartRate | > 100 bpm | > 120 bpm | 上限 |
| bodyTemperature | > 37.5 ℃ | > 38.5 ℃ | 上限 |
| spo2 | < 95 % | < 90 % | 下限 |

判定結果は `serverStatus` フィールドに `"normal"` / `"warning"` / `"critical"` で記録されます。

### 3. Blob Storage 出力

全メッセージを加工済み JSON として `processed` コンテナに保存します。

**Blob パス:** `{deviceId}/{YYYY-MM-DD}/{HH-mm-ss-ffffff}.json`

**出力 JSON 例:**

```json
{
  "deviceId": "icu-device01",
  "timestamp": "2026-02-19T00:57:16Z",
  "heartRate": 111,
  "bloodPressureSystolic": 141,
  "bloodPressureDiastolic": 80,
  "bodyTemperature": 38.5,
  "spo2": 92,
  "respiratoryRate": 20,
  "patientStatus": "warning",
  "processedAt": "2026-02-19T00:57:17Z",
  "serverStatus": "warning",
  "alerts": [
    "heartRate:elevated",
    "bodyTemperature:elevated",
    "spo2:elevated"
  ]
}
```

### 4. critical 時の Logic Apps 通知

`serverStatus` が `"critical"` の場合のみ、Logic Apps の HTTP Webhook にアラートを POST します。`LOGIC_APP_URL` が未設定の場合はスキップされます。

## アプリ設定 (環境変数)

| 設定名 | 説明 | 必須 |
|---|---|---|
| `IoTHubEventHubConnectionString` | IoT Hub の EventHub 互換エンドポイント接続文字列 | Yes |
| `IoTHubEventHubName` | IoT Hub 名 (EventHub 名として使用) | Yes |
| `IoTHubConsumerGroup` | コンシューマーグループ名 (`functions-cg`) | Yes |
| `ProcessedBlobConnectionString` | 出力先ストレージアカウントの接続文字列 | Yes |
| `ProcessedBlobContainerName` | 出力先コンテナ名 (デフォルト: `processed`) | No |
| `LOGIC_APP_URL` | Logic Apps の HTTP トリガー URL | No |
| `AzureWebJobsStorage` | Functions ランタイム用ストレージ | Yes |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Application Insights 接続文字列 | Yes |

## ビルド & デプロイ

### 前提条件

- .NET SDK 10.0 以上
- Azure Functions Core Tools v4
- Azure CLI

### ローカルビルド

```bash
cd functions-app-csharp
dotnet build
```

### Azure へのデプロイ

```bash
# 1. Release ビルド
dotnet publish -c Release -o ./publish

# 2. デプロイ
func azure functionapp publish <FUNCTION_APP_NAME> --dotnet-isolated
```

### 現在のデプロイ先

- **Function App:** `<your-function-app>`
- **リソースグループ:** `<your-resource-group>`
- **リージョン:** Japan East
- **SKU:** Flex Consumption

## NuGet パッケージ

| パッケージ | バージョン | 用途 |
|---|---|---|
| Microsoft.Azure.Functions.Worker | 2.51.0 | Isolated worker ランタイム |
| Microsoft.Azure.Functions.Worker.Extensions.EventHubs | 6.5.0 | EventHub トリガー |
| Azure.Storage.Blobs | 12.27.0 | Blob Storage 出力 |
| Microsoft.ApplicationInsights.WorkerService | 2.23.0 | Application Insights |
| Microsoft.Azure.Functions.Worker.Extensions.Http.AspNetCore | 2.1.0 | HTTP 拡張 |
| Microsoft.Azure.Functions.Worker.Sdk | 2.0.7 | Worker SDK |
