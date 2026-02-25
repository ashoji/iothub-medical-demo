# Logic Apps - Critical アラートメール通知

Azure Functions が `serverStatus == "critical"` を検知した際に、Logic Apps 経由でメール通知を送信します。

## 概要

```
Azure Functions (ProcessTelemetry)
    │ serverStatus == "critical"
    │ HTTP POST (JSON)
    ▼
Logic Apps (HTTP トリガー)
    │
    ▼
メール送信 (Outlook / SendGrid)
    │
    ▼
管理者のメールボックス
```

## アラート JSON ペイロード

Functions が Logic Apps に POST する JSON:

```json
{
  "deviceId": "icu-device01",
  "timestamp": "2026-02-19T00:57:16Z",
  "serverStatus": "critical",
  "alerts": ["heartRate:high", "spo2:low"],
  "heartRate": 125,
  "bodyTemperature": 39.1,
  "spo2": 88,
  "message": "[CRITICAL] icu-device01: heartRate=125, bodyTemperature=39.1, spo2=88 (heartRate:high, spo2:low)"
}
```

---

## 手順 1: Logic App を作成

1. [Azure Portal](https://portal.azure.com) にログイン
2. 上部の検索バーで **「Logic Apps」** を検索 → 選択
3. **「+ 追加」** をクリック
4. 以下を入力:

   | 項目 | 値 |
   |---|---|
   | サブスクリプション | Visual Studio Enterprise |
   | リソースグループ | `<your-resource-group>` |
   | Logic App 名 | `<your-logic-app>` |
   | リージョン | Japan East |
   | プランの種類 | **消費 (Consumption)** |
   | ゾーン冗長 | 無効 |

5. **「確認と作成」→「作成」** をクリック
6. デプロイ完了後 **「リソースに移動」**

---

## 手順 2: ワークフローを設計

### 2-1. デザイナーを開く

1. 「開発ツール」→ **「Logic App デザイナー」** をクリック
2. テンプレート選択画面が出たら **「空のロジック アプリ」** を選択

### 2-2. トリガー: HTTP 要求の受信時

1. トリガーの検索で **「HTTP」** と入力
2. **「HTTP 要求の受信時 (When a HTTP request is received)」** を選択
3. **「サンプルのペイロードを使用してスキーマを生成」** をクリック
4. 以下の JSON を貼り付けて **「完了」**:

```json
{
  "deviceId": "icu-device01",
  "timestamp": "2026-02-19T00:57:16Z",
  "serverStatus": "critical",
  "alerts": ["heartRate:high", "spo2:low"],
  "heartRate": 125,
  "bodyTemperature": 39.1,
  "spo2": 88,
  "message": "[CRITICAL] icu-device01: heartRate=125, bodyTemperature=39.1, spo2=88 (heartRate:high, spo2:low)"
}
```

自動生成されるスキーマ:

```json
{
  "type": "object",
  "properties": {
    "deviceId": { "type": "string" },
    "timestamp": { "type": "string" },
    "serverStatus": { "type": "string" },
    "alerts": {
      "type": "array",
      "items": { "type": "string" }
    },
    "heartRate": { "type": "number" },
    "bodyTemperature": { "type": "number" },
    "spo2": { "type": "number" },
    "message": { "type": "string" }
  }
}
```

### 2-3. アクション: メール送信

1. **「+ 新しいステップ」** をクリック
2. コネクタを選択（以下のいずれか）:

#### 選択肢 A: Office 365 Outlook（組織アカウント向け）

- **「Office 365 Outlook」** で検索 → **「メールの送信 (V2)」** を選択
- Microsoft 365 アカウントでサインイン

#### 選択肢 B: Outlook.com（個人アカウント向け）

- **「Outlook.com」** で検索 → **「メールの送信 (V2)」** を選択
- 個人 Microsoft アカウント (MSDN) でサインイン

#### 選択肢 C: SendGrid（アカウント不問）

- **「SendGrid」** で検索 → **「メールの送信 (V4)」** を選択
- SendGrid API Key を入力

### 2-4. メールの内容を設定

#### 宛先

```
（自分のメールアドレスを入力）
```

#### 件名

```
🚨 [CRITICAL] デバイス異常: @{triggerBody()?['deviceId']}
```

設定方法:
1. 件名欄に `🚨 [CRITICAL] デバイス異常: ` と入力
2. **「動的なコンテンツ」** タブをクリック
3. **`deviceId`** を選択

#### 本文

```
⚠️ 医療デバイス異常検知アラート
━━━━━━━━━━━━━━━━━━━━━━━━━━

■ デバイス情報
  デバイスID: @{triggerBody()?['deviceId']}
  検知時刻:   @{triggerBody()?['timestamp']}
  ステータス: @{triggerBody()?['serverStatus']}

■ バイタルサイン
  心拍数:     @{triggerBody()?['heartRate']} bpm
  体温:       @{triggerBody()?['bodyTemperature']} ℃
  SpO2:       @{triggerBody()?['spo2']} %

■ アラート詳細
  @{triggerBody()?['message']}

━━━━━━━━━━━━━━━━━━━━━━━━━━
※ このメールは Azure Functions + Logic Apps により自動送信されています。
```

設定方法:
1. 本文欄に上記テキストを入力
2. `@{triggerBody()?['...']}` の部分は **「動的なコンテンツ」** から該当フィールドを選択して置き換える

### 2-5. 保存

1. デザイナー上部の **「保存」** をクリック

---

## 手順 3: HTTP トリガー URL を取得

1. 保存後、**「HTTP 要求の受信時」** トリガーをクリックして展開
2. **「HTTP POST の URL」** が表示される
3. この URL をコピー

URL の形式:
```
https://prod-XX.japaneast.logic.azure.com:443/workflows/xxxxxxxx/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=xxxxxxxxxx
```

---

## 手順 4: Function App に URL を設定

Azure Portal または CLI で設定:

### Portal の場合

1. **「Function App」** → `<your-function-app>` を開く
2. **「設定」→「環境変数」** (または「構成」)
3. `LOGIC_APP_URL` の値に、コピーした URL を貼り付け
4. **「保存」→「続行」**

### CLI の場合

```bash
az functionapp config appsettings set \
  -n <your-function-app> \
  -g <your-resource-group> \
  --settings "LOGIC_APP_URL=https://prod-XX.japaneast.logic.azure.com:443/workflows/..."
```

---

## 手順 5: テスト

### 5-1. 手動テスト（curl）

Logic App の URL に直接 POST してメールが届くか確認:

```bash
curl -X POST "（Logic App の URL）" \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "test-device",
    "timestamp": "2026-02-19T12:00:00Z",
    "serverStatus": "critical",
    "alerts": ["heartRate:high", "spo2:low"],
    "heartRate": 130,
    "bodyTemperature": 39.5,
    "spo2": 85,
    "message": "[CRITICAL] test-device: heartRate=130, bodyTemperature=39.5, spo2=85 (heartRate:high, spo2:low)"
  }'
```

### 5-2. デバイスシミュレータでの E2E テスト

critical 率を高めに設定してテスト:

```bash
cd device-simulator
set -a && source ../.env && set +a
source .venv/bin/activate
timeout 30 python3 device_simulator.py icu-device01 telemetry \
  --interval 3000 --warning-rate 30 --critical-rate 50
```

---

## 手順 6: 実行履歴の確認

1. Azure Portal → `<your-logic-app>` を開く
2. **「概要」** の「実行の履歴」で成功/失敗を確認
3. 各実行をクリックすると入力/出力の詳細が表示される

---

## 注意事項

- **コスト**: Consumption プランでは、実行 1 回あたり約 ¥0.01 程度（アクション数による）
- **スロットリング**: critical が連続すると大量のメールが届く可能性あり。本番環境では Functions 側で重複抑制を実装推奨
- **URL の秘密管理**: Logic App の HTTP トリガー URL には SAS トークンが含まれるため、漏洩に注意
- **タイムゾーン**: timestamp は UTC。メール内で JST 表示したい場合は Logic Apps の `convertTimeZone` 関数を使用

## Azure リソース

| リソース | 名前 |
|---|---|
| Logic App | `<your-logic-app>` |
| Function App | `<your-function-app>` |
| リソースグループ | `<your-resource-group>` |
| リージョン | Japan East |
