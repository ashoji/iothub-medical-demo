# アーキテクチャ設計書: IoT 医療デモ バックエンド

## システム全体構成

```
┌─────────────────────────────────────────────────────────────────────┐
│  デバイス側 (オンプレ / エッジ)                                      │
│                                                                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │
│  │icu-      │ │icu-      │ │general-  │ │general-  │ │general-  │ │
│  │device01  │ │device02  │ │device01  │ │device02  │ │device03  │ │
│  │(重症)    │ │(回復中)  │ │(一般)    │ │(経過観察│  │(悪化傾向)│ │
│  └─────┬────┘ └─────┬────┘ └─────┬────┘ └─────┬────┘ └─────┬────┘ │
│        │            │            │            │            │       │
│        └────────────┴────────┬───┴────────────┴────────────┘       │
│                              │ MQTT                                │
└──────────────────────────────┼─────────────────────────────────────┘
                               │
┌──────────────────────────────┼─────────────────────────────────────┐
│  Azure クラウド              │                                     │
│                              ▼                                     │
│  ┌──────────────────────────────────────────┐                      │
│  │  IoT Hub                                  │                     │
│  │  <your-iothub-name>           │                     │
│  │  (S1, japaneast, partition:2)             │                     │
│  └──────┬────────────────────────┬───────────┘                     │
│         │                        │                                 │
│         │ メッセージルーティング  │ Event Hub 互換エンドポイント     │
│         │                        │ (consumer group: functions-cg)  │
│         ▼                        ▼                                 │
│  ┌──────────────┐   ┌───────────────────────────────┐              │
│  │ Blob Storage  │   │  Azure Functions               │             │
│  │ /telemetry    │   │  <your-function-app>           │             │
│  │ (生データ)    │   │  (Flex Consumption, .NET 10.0)  │             │
│  └──────────────┘   └──────┬──────────────┬──────────┘             │
│                            │              │                        │
│                 Blob SDK   │              │ HTTP POST              │
│                            ▼              ▼                        │
│                   ┌──────────────┐  ┌──────────────┐               │
│                   │ Blob Storage  │  │ Logic Apps    │              │
│                   │ /processed    │  │ (HTTP trigger │              │
│                   │ (加工済み)    │  │  → メール)    │              │
│                   └───────┬──────┘  └──────┬───────┘               │
│                           │                │                       │
│                           ▼                ▼                       │
│                   ┌──────────────┐  ┌──────────────┐               │
│                   │  Power BI    │  │  メール通知   │               │
│                   │  (可視化)    │  │  (critical)   │               │
│                   └──────────────┘  └──────────────┘               │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## コンポーネント詳細

### 1. デバイスシミュレータ

| 項目 | 内容 |
|---|---|
| 実装 | `device-simulator/device_simulator.py` (Python) |
| プロトコル | MQTT (azure-iot-device SDK) |
| 機能 | テレメトリ送信、ファイルアップロード、C2D メッセージ受信 |
| 起動スクリプト | `device-simulator/run_all_devices.sh` (5台並行起動) |

### 2. IoT Hub

| 項目 | 内容 |
|---|---|
| 名前 | <your-iothub-name> |
| SKU | S1 (400,000メッセージ/日) |
| リージョン | japaneast |
| パーティション数 | 2 |
| 認証 | Managed Identity (Storage 向け) + SAS Key (デバイス向け) |

**メッセージルーティング:**

| ルート名 | ソース | 条件 | エンドポイント |
|---|---|---|---|
| TelemetryRoute | DeviceMessages | true (全メッセージ) | BlobStorageEndpoint |
| EventsRoute | DeviceMessages | true (全メッセージ) | events (組み込み Event Hub) |

**エンドポイント:**

| 名前 | 種別 | コンテナ | ファイル形式 |
|---|---|---|---|
| BlobStorageEndpoint | Blob Storage | telemetry | `{iothub}/{partition}/{YYYY}/{MM}/{DD}/{HH}/{mm}.json` |

**コンシューマグループ:**

| 名前 | 用途 |
|---|---|
| $Default | 既定 (未使用) |
| functions-cg | Azure Functions 用 (新規) |

### 3. Azure Functions

| 項目 | 内容 |
|---|---|
| 名前 | `<your-function-app>` |
| プラン | Flex Consumption |
| ランタイム | .NET 10.0 (isolated worker) |
| プログラミングモデル | C# isolated worker model |
| 関数数 | 1 (`ProcessTelemetry`) |

**データフロー:**

```
EventHub メッセージ (バッチ, max 64件)
  │
  ├─ JSON パース
  │     ↓ 失敗時: ログ出力してスキップ
  │
  ├─ evaluate_status()
  │     ├─ heartRate  > 120 → critical / > 100 → warning
  │     ├─ bodyTemp   > 38.5 → critical / > 37.5 → warning
  │     └─ spo2       < 90  → critical / < 95  → warning
  │
  ├─ build_processed_record()
  │     └─ 元データ + processedAt + serverStatus + alerts
  │
  ├─ upload_to_blob()
  │     └─ /processed/{deviceId}/{YYYY-MM-DD}/{HH-mm-ss-ffffff}.json
  │
  └─ [serverStatus == "critical" の場合]
        ├─ build_alert_payload()
        └─ notify_logic_app() → HTTP POST → Logic Apps
```

### 4. Blob Storage

| 項目 | 内容 |
|---|---|
| アカウント名 | `<your-storage-account>` |
| SKU | Standard_LRS |
| リージョン | japaneast |

**コンテナ構成:**

| コンテナ | 書き込み元 | 形式 | 用途 |
|---|---|---|---|
| telemetry | IoT Hub ルーティング | JSON Lines (バッチ) | 生データアーカイブ |
| processed | Azure Functions | 個別 JSON ファイル | Power BI 取り込み用 |
| image | IoT Hub ファイルアップロード | バイナリ (画像等) | デバイスからのファイル |

**Blob パス規則:**

```
telemetry/
  └─ {iothubName}/{partition}/{YYYY}/{MM}/{DD}/{HH}/{mm}.json   ← IoT Hub ルーティング

processed/
  └─ {deviceId}/{YYYY-MM-DD}/{HH-mm-ss-ffffff}.json             ← Functions 出力

image/
  └─ (デバイスからのアップロード)                                 ← ファイルアップロード
```

### 5. Logic Apps

| 項目 | 内容 |
|---|---|
| 名前 | <your-logic-app> |
| プラン | Consumption |
| トリガー | HTTP Request (POST) |
| アクション | Office 365 Outlook メール送信 |

**フロー:**

```
HTTP Request (POST, JSON body)
  ↓
JSON パース (deviceId, timestamp, alerts, message)
  ↓
メール送信
  宛先: 管理者メールアドレス
  件名: [CRITICAL] 医療デバイス異常検知 - {deviceId}
  本文: デバイス情報 + 異常詳細
```

### 6. Power BI

| 項目 | 内容 |
|---|---|
| データソース | Blob Storage /processed コンテナ |
| 接続方法 | Azure Blob Storage コネクタ → フォルダ結合 |
| 更新方式 | スケジュール更新 or オンデマンド |

---

## セキュリティ

| 通信路 | 認証方式 |
|---|---|
| デバイス → IoT Hub | デバイス SAS Key (接続文字列) |
| IoT Hub → Blob (ルーティング) | Managed Identity (Storage Blob Data Contributor) |
| IoT Hub → Functions | Event Hub 互換エンドポイント SAS (接続文字列) |
| Functions → Blob (processed) | Storage Account 接続文字列 |
| Functions → Logic Apps | Logic Apps HTTP トリガー URL (SAS トークン付き) |

※ デモ用途のため接続文字列ベース。本番環境では Managed Identity + Key Vault を推奨。

---

## データ量試算 (3時間運用)

| 項目 | 計算 | 結果 |
|---|---|---|
| ICU メッセージ | 2台 x 360件/時 x 3時間 | 2,160件 |
| General メッセージ | 3台 x 120件/時 x 3時間 | 1,080件 |
| **合計メッセージ** | | **3,240件** |
| /telemetry Blob ファイル | ~1分バッチ x 2パーティション x 180分 | ~360ファイル |
| /processed Blob ファイル | 1メッセージ = 1ファイル | ~3,240ファイル |
| /processed データサイズ | ~400bytes/件 x 3,240件 | ~1.3 MB |
| critical イベント (推定) | icu-01: 5%, icu-02: 0.3%, gen-03: 3% | ~108件 |

---

## フォルダ構成 (リポジトリ全体)

```
iothub/
├── .env                         # bash 環境変数
├── .env.ps1                     # PowerShell 環境変数
├── iothub.sln                   # Visual Studio ソリューション
├── azure-scripts/
│   ├── setup-msdn.sh            # MSDN サブスクリプション向けセットアップ
│   ├── setup-resources.ps1      # PowerShell でのリソース作成
│   ├── setup-functions.sh       # Functions デプロイ用
│   └── phase2-step.sh           # フェーズ 2 ステップ
├── device-simulator/
│   ├── device_simulator.py      # Python デバイスシミュレータ (メイン)
│   ├── device_simulator.c       # C デバイスシミュレータ (参考実装)
│   ├── CMakeLists.txt           # C 版ビルド定義
│   ├── run_all_devices.sh       # 5台並行起動スクリプト
│   └── requirements.txt
├── management-app/
│   ├── device_manager.py        # C2D メッセージ送信 (Python)
│   ├── device_manager.c         # C2D メッセージ送信 (C)
│   ├── CMakeLists.txt           # C 版ビルド定義
│   └── requirements.txt
├── functions-app-csharp/        # ★ Azure Functions バックエンド (C# .NET 10.0)
│   ├── ProcessTelemetry.cs      # EventHub Trigger → Blob / Logic Apps
│   ├── Program.cs               # DI 設定
│   ├── FunctionsApp.csproj      # プロジェクト定義
│   ├── host.json
│   ├── local.settings.json
│   ├── Properties/launchSettings.json
│   └── README.md
├── logic-app/
│   └── README.md                # Logic Apps 作成手順
├── powerbi/
│   └── README.md                # Power BI ダッシュボード構築手順
└── docs/                        # ドキュメント
    ├── prd-functions.md
    ├── implementation-plan.md
    └── architecture.md
```
