# IoT Hub 医療デバイス監視デモ

Azure IoT Hub を中心とした医療デバイス遠隔監視システムのデモプロジェクトです。  
デバイスシミュレータから送信されたバイタルサインデータを、Azure Functions でリアルタイム処理し、異常検知時は Logic Apps 経由でメール通知、蓄積データは Power BI で可視化します。
全体像を理解するため、あえて基本的なアーキテクチャにしているため、運用環境での利用にステップアップする場合は、セキュリティを大幅に強化したアーキテクチャを追加実装する必要があります。

---

## アーキテクチャ

```
┌─────────────────────────────────────────────────────────────────────┐
│  デバイス側 (オンプレ / エッジ)                                      │
│                                                                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │
│  │icu-      │ │icu-      │ │general-  │ │general-  │ │general-  │ │
│  │device01  │ │device02  │ │device01  │ │device02  │ │device03  │ │
│  │(重症)    │ │(回復中)  │ │(一般)    │ │(経過観察)│ │(悪化傾向)│ │
│  └─────┬────┘ └─────┬────┘ └─────┬────┘ └─────┬────┘ └─────┬────┘ │
│        └────────────┴────────┬───┴────────────┴────────────┘       │
│                              │ MQTT (azure-iot-device SDK)         │
└──────────────────────────────┼─────────────────────────────────────┘
                               │
┌──────────────────────────────┼─────────────────────────────────────┐
│  Azure クラウド (Japan East) │                                     │
│                              ▼                                     │
│  ┌──────────────────────────────────────────┐                      │
│  │  IoT Hub (S1)                             │                     │
│  │  <your-iothub-name>                 │                     │
│  └──────┬────────────────────────┬───────────┘                     │
│         │                        │                                 │
│         │ メッセージルーティング  │ EventHub 互換エンドポイント      │
│         │ (TelemetryRoute)       │ (ConsumerGroup: functions-cg)   │
│         ▼                        ▼                                 │
│  ┌──────────────┐   ┌───────────────────────────────┐              │
│  │ Blob Storage  │   │  Azure Functions               │             │
│  │ /telemetry    │   │  <your-function-app>        │             │
│  │ (生データ)    │   │  (Flex Consumption, .NET 10.0) │             │
│  └──────────────┘   └──────┬──────────────┬──────────┘             │
│                            │              │                        │
│                 Blob SDK   │              │ HTTP POST              │
│                            ▼              ▼                        │
│                   ┌──────────────┐  ┌──────────────┐               │
│                   │ Blob Storage  │  │ Logic Apps    │              │
│                   │ /processed    │  │ (HTTP trigger │              │
│                   │ (加工済み)    │  │  → メール)    │              │
│                   └───────┬──────┘  └──────────────┘               │
│                           │                                        │
│                           ▼                                        │
│                   ┌──────────────┐                                  │
│                   │  Power BI    │                                  │
│                   │  Desktop     │                                  │
│                   └──────────────┘                                  │
└────────────────────────────────────────────────────────────────────┘
```

### データフロー

1. **デバイスシミュレータ** が MQTT でバイタルサインを IoT Hub に送信
2. **IoT Hub** がメッセージを 2 つのルートに振り分け:
   - `TelemetryRoute` → Blob Storage (`telemetry` コンテナ) に生データ保存
   - `EventsRoute` → EventHub 互換エンドポイント経由で Functions にストリーム配信
3. **Azure Functions** (`ProcessTelemetry`) がバイタルを再判定し、加工済み JSON を `processed` コンテナに保存
4. `serverStatus == "critical"` の場合、**Logic Apps** に HTTP POST でアラート通知 → メール送信
5. **Power BI Desktop** が `processed` コンテナから JSON を読み込み、ダッシュボードで可視化

---

## Azure リソース一覧

| リソース | 名前 | 用途 |
|---|---|---|
| リソースグループ | `<your-resource-group>` | 全リソースの管理単位 |
| IoT Hub (S1) | `<your-iothub-name>` | デバイス接続 & メッセージルーティング |
| Storage Account | `<your-storage-account>` | テレメトリデータ格納 (telemetry / processed / image) |
| Storage Account | `<your-func-storage-account>` | Functions ランタイム用 (AzureWebJobsStorage) |
| Function App | `<your-function-app>` | テレメトリ処理 (Flex Consumption, .NET 10.0) |
| Logic App | `<your-logic-app>` | Critical アラートメール通知 (Consumption) |

| サブスクリプション | Visual Studio Enterprise |
|---|---|
| リージョン | Japan East |

---

## デバイス一覧

| デバイスID | 種別 | シナリオ | 送信間隔 | warning 率 | critical 率 |
|---|---|---|---|---|---|
| `icu-device01` | ICU | 重症患者 | 10 秒 | 20% | 5% |
| `icu-device02` | ICU | 安定回復中 | 10 秒 | 5% | 0.3% |
| `general-device01` | 一般 | 一般入院 | 30 秒 | 8% | 0.5% |
| `general-device02` | 一般 | 経過観察 | 30 秒 | 3% | 0.1% |
| `general-device03` | 一般 | 容態悪化傾向 | 30 秒 | 15% | 3% |

**3 時間実行時の想定メッセージ数:** 約 3,240 件 (ICU: 1,080×2, 一般: 360×3)

---

## ステータス判定閾値 (クラウド側)

Functions (`ProcessTelemetry`) がデバイス側とは独立にバイタルを再判定します。

| バイタル | warning | critical | チェック方向 |
|---|---|---|---|
| 心拍数 (heartRate) | > 100 bpm | > 120 bpm | 上限 |
| 体温 (bodyTemperature) | > 37.5 ℃ | > 38.5 ℃ | 上限 |
| SpO2 (spo2) | < 95 % | < 90 % | 下限 |

判定結果は `serverStatus` フィールドに `"normal"` / `"warning"` / `"critical"` で記録されます。

---

## プロジェクト構成

```
iothub/
├── README.md                     ← 本ファイル (プロジェクト全体の説明)
├── .env                          ← 接続文字列・環境変数 (Linux/WSL 用)
├── .env.ps1                      ← 接続文字列・環境変数 (PowerShell 用)
├── .gitignore
├── iothub.sln                    ← Visual Studio ソリューション
│
├── device-simulator/             ← デバイスシミュレータ
│   ├── device_simulator.py       ← メインスクリプト (Python 3.12)
│   ├── device_simulator.c        ← C 版 (参考実装、Azure IoT C SDK 必要)
│   ├── CMakeLists.txt            ← C 版ビルド定義
│   ├── run_all_devices.sh        ← 5 台並行起動スクリプト (3 時間)
│   └── requirements.txt          ← Python 依存パッケージ
│
├── functions-app-csharp/         ← Azure Functions (C# .NET 10.0 isolated worker)
│   ├── ProcessTelemetry.cs       ← EventHub Trigger → Blob Storage / Logic Apps
│   ├── Program.cs                ← DI 設定 (HttpClientFactory, ApplicationInsights)
│   ├── FunctionsApp.csproj       ← プロジェクト定義
│   ├── host.json                 ← Functions ホスト設定
│   ├── local.settings.json       ← ローカル実行用設定
│   ├── Properties/
│   │   └── launchSettings.json   ← デバッグ起動設定
│   └── README.md                 ← 詳細ドキュメント
│
├── logic-app/                    ← Logic Apps セットアップガイド
│   └── README.md                 ← Azure Portal での作成手順
│
├── powerbi/                      ← Power BI Desktop セットアップガイド
│   └── README.md                 ← データ接続 & ダッシュボード設計
│
├── docs/                         ← 設計ドキュメント
│   ├── architecture.md           ← アーキテクチャ設計書
│   ├── implementation-plan.md    ← 実装計画
│   └── prd-functions.md          ← Functions 要件定義
│
├── azure-scripts/                ← Azure リソース構築スクリプト
│   ├── setup-msdn.sh             ← MSDN サブスクリプション向けセットアップ
│   ├── setup-resources.ps1       ← PowerShell でのリソース作成
│   ├── setup-functions.sh        ← Functions デプロイ用
│   └── phase2-step.sh            ← フェーズ 2 ステップ
│
└── management-app/               ← 管理アプリ (C / Python) ※参考実装
    ├── device_manager.py         ← Python 版
    ├── device_manager.c          ← C 版 (Azure IoT C SDK 必要)
    ├── CMakeLists.txt            ← C 版ビルド定義
    └── requirements.txt          ← Python 依存パッケージ
```

---

## クイックスタート

### 前提条件

- Python 3.12+
- .NET SDK 10.0
- Azure Functions Core Tools v4
- Azure CLI (`az login` 済み)

### 1. 環境セットアップ

```bash
cd iothub

# Python 仮想環境 (device-simulator 用)
cd device-simulator
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..

# 環境変数の読み込み
source .env        # Linux/WSL
# . .env.ps1      # PowerShell の場合
```

### 2. デバイスシミュレータの実行

```bash
# 単体テスト (1 台)
cd device-simulator
python3 device_simulator.py --mode telemetry --device-id icu-device01

# 5 台並行実行 (3 時間 → Power BI 分析用データ生成)
bash run_all_devices.sh
```

### 3. Azure Functions のローカル実行

```bash
cd functions-app-csharp
dotnet build
func start
```

### 4. Azure Functions のデプロイ

```bash
cd functions-app-csharp
func azure functionapp publish <your-function-app> --dotnet-isolated
```

---

## 各コンポーネントの詳細ドキュメント

| コンポーネント | ドキュメント | 概要 |
|---|---|---|
| Azure Functions | [functions-app-csharp/README.md](functions-app-csharp/README.md) | 処理フロー、閾値、アプリ設定、NuGet パッケージ |
| Logic Apps | [logic-app/README.md](logic-app/README.md) | Azure Portal での作成手順 (6 ステップ) |
| Power BI | [powerbi/README.md](powerbi/README.md) | データ接続、Power Query M コード、3 ページ構成 |
| アーキテクチャ設計 | [docs/architecture.md](docs/architecture.md) | システム全体のアーキテクチャ詳細 |
| 実装計画 | [docs/implementation-plan.md](docs/implementation-plan.md) | フェーズ別の実装計画 |
| 要件定義 | [docs/prd-functions.md](docs/prd-functions.md) | Functions の機能要件 |

---

## テレメトリ JSON スキーマ

### デバイス送信 (IoT Hub → telemetry コンテナ)

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
  "patientStatus": "warning"
}
```

### 加工済み (processed コンテナ → Power BI)

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
  "alerts": ["heartRate:elevated", "bodyTemperature:elevated", "spo2:elevated"]
}
```

---

## IoT Hub メッセージルーティング

| ルート名 | ソース | 条件 | エンドポイント |
|---|---|---|---|
| `TelemetryRoute` | DeviceMessages | `true` | BlobStorageEndpoint (`telemetry` コンテナ) |
| `EventsRoute` | DeviceMessages | `true` | events (組み込み EventHub 互換 EP) |

---

## ライセンス

デモ・学習目的のプロジェクトです。