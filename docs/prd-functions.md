# PRD: Azure Functions - IoT テレメトリ処理バックエンド

## 概要

IoT Hub から送信される医療デバイスのテレメトリデータをリアルタイムで処理し、
加工済みデータの Blob 保存と、critical イベント時のメール通知を行う Azure Functions アプリケーション。

## 背景・目的

- **ワークショップ向けデモ**: IoT バックエンドの典型的なアーキテクチャを体験してもらう
- デバイスシミュレータ (5台) から送信されるテレメトリをクラウド側で処理する
- 2つのユースケースを実現:
  1. **医療データの可視化** — Power BI でのダッシュボード分析
  2. **異常検知とメール通知** — critical イベント時の即座のアラート

## アーキテクチャ

```
IoT Hub (Event Hub 互換エンドポイント)
  │
  ├─ メッセージルーティング → Blob Storage /telemetry (生データ保存, 既存)
  │
  └─ EventHub トリガー → ★ Azure Functions (この PRD のスコープ)
                            │
                            ├─ Blob Storage /processed (加工済み JSON 出力)
                            │    └─ Power BI で取り込み・可視化
                            │
                            └─ HTTP POST → Logic Apps (critical 時メール通知)
                                 └─ メール送信
```

## スコープ

### In Scope

- Azure Functions (C# .NET 10.0 isolated worker, Flex Consumption Plan)
- Event Hub トリガーによるテレメトリ受信
- クラウド側ステータス再判定ロジック
- 加工済み JSON の Blob 出力 (`/processed` コンテナ)
- Logic Apps への HTTP POST (critical アラート)

### Out of Scope

- Logic Apps 自体の実装 (別ドキュメント)
- Power BI ダッシュボードの構築
- デバイスシミュレータの改修
- デバイス管理 (C2D メッセージ)

---

## 入力データ仕様

### イベントソース

| 項目 | 値 |
|---|---|
| ソース | IoT Hub 組み込み Event Hub 互換エンドポイント |
| IoT Hub 名 | `<your-iothub-name>` |
| パーティション数 | 2 |
| コンシューマグループ | `functions-cg` (新規作成) |
| プロトコル | AMQP |

### テレメトリ JSON スキーマ (メッセージ Body)

```json
{
  "deviceId": "icu-device01",
  "timestamp": "2026-02-18T04:19:32Z",
  "heartRate": 78,
  "bloodPressureSystolic": 125,
  "bloodPressureDiastolic": 82,
  "bodyTemperature": 36.8,
  "spo2": 98,
  "respiratoryRate": 15.2,
  "patientStatus": "normal"
}
```

### フィールド定義

| フィールド | 型 | 説明 | 値の範囲 |
|---|---|---|---|
| deviceId | string | デバイスID | icu-device01/02, general-device01~03 |
| timestamp | string (ISO8601) | デバイス側 UTC タイムスタンプ | — |
| heartRate | int | 心拍数 (bpm) | 60 ~ 160 |
| bloodPressureSystolic | int | 収縮期血圧 (mmHg) | 110 ~ 180 |
| bloodPressureDiastolic | int | 拡張期血圧 (mmHg) | 70 ~ 110 |
| bodyTemperature | float | 体温 (°C) | 36.0 ~ 40.0 |
| spo2 | int | 酸素飽和度 (%) | 80 ~ 100 |
| respiratoryRate | float | 呼吸数 (回/分) | 12.0 ~ 30.0 |
| patientStatus | string | デバイス側判定ステータス | normal / warning / critical |

### デバイス構成 (5台)

| デバイス | 患者設定 | 送信間隔 | Warning率 | Critical率 |
|---|---|---|---|---|
| icu-device01 | 重症患者 | 10秒 | 20% | 5% |
| icu-device02 | 安定回復中 | 10秒 | 5% | 0.3% |
| general-device01 | 一般入院 | 30秒 | 8% | 0.5% |
| general-device02 | 経過観察 | 30秒 | 3% | 0.1% |
| general-device03 | 容態悪化傾向 | 30秒 | 15% | 3% |

---

## 機能要件

### F1: テレメトリ受信・加工処理

- **トリガー**: Event Hub トリガー (バッチ処理, cardinality=MANY)
- **バッチ設定**: maxEventBatchSize=64, prefetchCount=128
- **処理内容**:
  1. メッセージ Body を JSON パース
  2. クラウド側でステータスを再判定 (デバイス側判定は参考値として保持)
  3. 加工フィールドを追加して出力

#### クラウド側ステータス判定ロジック

判定は critical → warning → normal の優先順位で行う。

| 指標 | Normal | Warning | Critical |
|---|---|---|---|
| heartRate | ≤ 100 | 101 ~ 120 | > 120 |
| bodyTemperature | ≤ 37.5 | 37.6 ~ 38.5 | > 38.5 |
| spo2 | ≥ 95 | 90 ~ 94 | < 90 |

- いずれか1指標でも critical 条件を満たせば `serverStatus = "critical"`
- critical がなく、いずれか1指標が warning 条件を満たせば `serverStatus = "warning"`
- すべて正常範囲なら `serverStatus = "normal"`

#### alerts フィールド生成ルール

| 条件 | alert 値 |
|---|---|
| heartRate > 120 | `heartRate:high` |
| heartRate > 100 (warning) | `heartRate:elevated` |
| bodyTemperature > 38.5 | `bodyTemperature:high` |
| bodyTemperature > 37.5 (warning) | `bodyTemperature:elevated` |
| spo2 < 90 | `spo2:low` |
| spo2 < 95 (warning) | `spo2:elevated` |

### F2: Blob 出力 (/processed コンテナ)

- **出力先パス**: `processed/{deviceId}/{YYYY-MM-DD}/{HH-mm-ss-ffffff}.json`
- **形式**: 1メッセージ = 1 JSON ファイル (Power BI 取り込みに最適)
- **実装方式**: Azure.Storage.Blobs SDK (動的パスのため Blob output binding ではなく SDK 直接使用)

#### 出力 JSON スキーマ

```json
{
  "deviceId": "icu-device01",
  "timestamp": "2026-02-18T04:19:32Z",
  "processedAt": "2026-02-18T04:19:33Z",
  "heartRate": 78,
  "bloodPressureSystolic": 125,
  "bloodPressureDiastolic": 82,
  "bodyTemperature": 36.8,
  "spo2": 98,
  "respiratoryRate": 15.2,
  "patientStatus": "normal",
  "serverStatus": "normal",
  "alerts": []
}
```

| 追加フィールド | 型 | 説明 |
|---|---|---|
| processedAt | string (ISO8601) | Functions 処理時刻 (UTC) |
| serverStatus | string | クラウド側再判定ステータス (normal/warning/critical) |
| alerts | array of string | 異常項目リスト |

### F3: Critical アラート通知

- **条件**: `serverStatus == "critical"` の場合のみ
- **アクション**: Logic Apps の HTTP Webhook エンドポイントに POST

#### POST Body

```json
{
  "deviceId": "icu-device01",
  "timestamp": "2026-02-18T04:19:32Z",
  "serverStatus": "critical",
  "alerts": ["heartRate:high", "spo2:low"],
  "heartRate": 135,
  "bodyTemperature": 36.8,
  "spo2": 85,
  "message": "[CRITICAL] icu-device01: heartRate=135, spo2=85 (heartRate:high, spo2:low)"
}
```

- **Logic Apps URL**: 環境変数 `LOGIC_APP_URL` から取得
- **未設定時の動作**: ログ出力のみ (エラーにしない、テレメトリ処理は継続)

---

## 非機能要件

### パフォーマンス

- 5台同時送信 (ICU 10秒間隔 x 2 + General 30秒間隔 x 3) に対応
- 3時間連続稼働で約 3,240件のメッセージを処理
- バッチ処理により Functions の起動回数を最適化

### エラーハンドリング

| エラー種別 | 対応 |
|---|---|
| JSON パース失敗 | ログ出力してスキップ (バッチ全体を落とさない) |
| Blob 出力失敗 | ログ出力してスキップ (Functions ランタイムのリトライに委任) |
| Logic Apps POST 失敗 | ログ出力してスキップ (テレメトリ処理を止めない) |

### ログ出力

| レベル | 内容 |
|---|---|
| INFO | バッチ処理完了サマリ (処理件数, critical 件数, エラー件数) |
| WARNING | `LOGIC_APP_URL` 未設定時のスキップ / critical イベント検出 |
| ERROR | JSON パース失敗 / Blob 出力失敗 / Logic Apps 通知失敗 |
| DEBUG | Blob アップロード成功 (個別) |

---

## Azure リソース

### 既存リソース

| リソース | 名前 | リージョン |
|---|---|---|
| リソースグループ | <your-resource-group> | japaneast |
| IoT Hub | <your-iothub-name> | japaneast |
| Storage Account | <your-storage-account> | japaneast |
| Blob コンテナ | telemetry | — |
| Blob コンテナ | image | — |

### 新規作成が必要なリソース

| リソース | 名前 | 備考 |
|---|---|---|
| Function App | <your-function-app> | .NET 10.0 isolated worker, Flex Consumption Plan, japaneast |
| Storage Account | (Functions 内部用) | Flex Consumption Plan で自動作成、またはデプロイ用 Storage |
| Blob コンテナ | processed | 既存 <your-storage-account> に追加 |
| コンシューマグループ | functions-cg | IoT Hub の Event Hub 互換エンドポイントに追加 |
| Logic Apps | <your-logic-app> | critical 時メール送信 (Phase 4) |

---

## 環境変数

| 変数名 | 説明 | 例 |
|---|---|---|
| IoTHubEventHubConnectionString | IoT Hub Event Hub 互換エンドポイント接続文字列 | `Endpoint=sb://...` |
| IoTHubEventHubName | Event Hub 互換名 (= IoT Hub 名) | `<your-iothub-name>` |
| IoTHubConsumerGroup | コンシューマグループ名 | `functions-cg` |
| ProcessedBlobConnectionString | 出力先 Storage Account 接続文字列 | `DefaultEndpointsProtocol=https;...` |
| ProcessedBlobContainerName | 出力先コンテナ名 | `processed` |
| LOGIC_APP_URL | Logic Apps HTTP トリガー URL (空文字でスキップ) | `https://prod-xx.japaneast.logic.azure.com/...` |

---

## 制約事項

- IoT Hub: S1 SKU (1日 400,000 メッセージ上限)
- Flex Consumption Plan: .NET 10.0 (isolated worker)
- デモ用途のため、認証は接続文字列ベースで簡易に実装
- Blob 出力は 1メッセージ = 1ファイル (小規模デモに適した設計、大規模運用には不向き)
