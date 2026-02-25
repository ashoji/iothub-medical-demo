#!/bin/bash
# ============================================================
# Azure IoT Hub デモ環境セットアップ (MSDN サブスクリプション用)
#
# - Managed Identity を使わず、すべてアクセスキー/接続文字列ベース
# - Flex Consumption Plan で Azure Functions を作成
# - device-simulator, functions-app, management-app の全環境変数を出力
#
# 前提:
#   az login --tenant <TENANT_ID> で MSDN サブスクリプションにログイン済み
#   az account set --subscription <SUB_ID>
#
# 実行: bash azure-scripts/setup-msdn.sh
# ============================================================
set -euo pipefail

# ========================================
# 1. 変数
# ========================================
RESOURCE_GROUP="<your-resource-group>"
LOCATION="japaneast"
TIMESTAMP=$(date +%s)
SHORT_TS=${TIMESTAMP: -9}                      # 末尾9桁
IOTHUB_NAME="iothub-medical-${SHORT_TS}"
STORAGE_ACCOUNT="stmedical${SHORT_TS}"
FUNC_STORAGE="stfuncmed${SHORT_TS}"
FUNC_APP_NAME="func-medical-${SHORT_TS}"
SKU="S1"

echo "==========================================="
echo " Azure IoT Hub デモ環境セットアップ (MSDN)"
echo "==========================================="
echo ""
echo "  Subscription : $(az account show --query name -o tsv)"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location      : $LOCATION"
echo "  IoT Hub       : $IOTHUB_NAME"
echo "  Storage (data): $STORAGE_ACCOUNT"
echo "  Storage (func): $FUNC_STORAGE"
echo "  Function App  : $FUNC_APP_NAME"
echo ""
read -p "この設定で続行しますか? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "キャンセルしました"
    exit 1
fi

# ========================================
# 2. リソースプロバイダーの登録
# ========================================
echo ""
echo "[2] リソースプロバイダーの登録確認..."
for ns in Microsoft.Devices Microsoft.Storage Microsoft.Web; do
    state=$(az provider show --namespace "$ns" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "$state" != "Registered" ]]; then
        echo "  $ns を登録中..."
        az provider register --namespace "$ns" -o none
        echo "  反映を待機中 (最大5分)..."
        for i in $(seq 1 30); do
            sleep 10
            state=$(az provider show --namespace "$ns" --query "registrationState" -o tsv)
            echo "    $state (${i}0秒)"
            [[ "$state" == "Registered" ]] && break
        done
    else
        echo "  $ns: 登録済み"
    fi
done

# ========================================
# 3. リソースグループ
# ========================================
echo ""
echo "[3] リソースグループ: $RESOURCE_GROUP"
if [[ "$(az group exists --name $RESOURCE_GROUP)" == "false" ]]; then
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none
    echo "  作成しました"
else
    echo "  既に存在します"
fi

# ========================================
# 4. ストレージアカウント (データ用)
# ========================================
echo ""
echo "[4] ストレージアカウント (データ用): $STORAGE_ACCOUNT"
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  -o none
echo "  作成しました"

# アクセスキー取得
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].value" -o tsv)

STORAGE_CONN_STR=$(az storage account show-connection-string \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query connectionString -o tsv)

# Blob コンテナ作成 (アクセスキー使用)
echo "  コンテナ作成中..."
az storage container create --name image      --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" -o none 2>/dev/null || true
az storage container create --name telemetry  --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" -o none 2>/dev/null || true
az storage container create --name processed  --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" -o none 2>/dev/null || true
echo "  コンテナ作成完了 (image, telemetry, processed)"

# ========================================
# 5. IoT Hub
# ========================================
echo ""
echo "[5] IoT Hub: $IOTHUB_NAME (数分かかります)..."
az iot hub create \
  --name "$IOTHUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku "$SKU" \
  --partition-count 2 \
  -o none
echo "  作成しました"

# ========================================
# 6. デバイス登録
# ========================================
echo ""
echo "[6] デバイス登録..."
for dev in icu-device01 icu-device02 general-device01 general-device02 general-device03; do
    az iot hub device-identity create \
      --hub-name "$IOTHUB_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --device-id "$dev" -o none 2>/dev/null || echo "  $dev: 既に存在"
    echo "  $dev: OK"
done

# ========================================
# 7. メッセージルーティング (接続文字列ベース)
# ========================================
echo ""
echo "[7] メッセージルーティング設定..."

# ストレージエンドポイント (接続文字列ベース、旧 CLI コマンド)
az iot hub routing-endpoint create \
  --hub-name "$IOTHUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --endpoint-name BlobStorageEndpoint \
  --endpoint-type azurestoragecontainer \
  --connection-string "$STORAGE_CONN_STR" \
  --container telemetry \
  --encoding json \
  --file-name-format '{iothub}/{partition}/{YYYY}/{MM}/{DD}/{HH}/{mm}.json' \
  -o none 2>&1 || echo "  [WARN] エンドポイント作成で警告あり"
echo "  エンドポイント作成完了"

az iot hub route create \
  --hub-name "$IOTHUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --route-name TelemetryRoute \
  --endpoint-name BlobStorageEndpoint \
  --source devicemessages \
  --enabled true \
  -o none
echo "  ルーティングルール作成完了"

# ========================================
# 8. ファイルアップロード設定 (接続文字列ベース)
# ========================================
echo ""
echo "[8] ファイルアップロード設定..."
az iot hub update \
  --name "$IOTHUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --fileupload-storage-connectionstring "$STORAGE_CONN_STR" \
  --fileupload-storage-container-name image \
  -o none
echo "  ファイルアップロード設定完了"

# ========================================
# 9. コンシューマグループ
# ========================================
echo ""
echo "[9] コンシューマグループ functions-cg..."
az iot hub consumer-group create \
  --hub-name "$IOTHUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --name functions-cg \
  -o none 2>/dev/null || true
echo "  作成完了"

# ========================================
# 10. Functions 用ストレージアカウント
# ========================================
echo ""
echo "[10] Functions 用ストレージアカウント: $FUNC_STORAGE"
az storage account create \
  --name "$FUNC_STORAGE" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  -o none
echo "  作成完了"

# ========================================
# 11. Function App (Flex Consumption)
# ========================================
echo ""
echo "[11] Function App: $FUNC_APP_NAME (Flex Consumption)..."
az functionapp create \
  --name "$FUNC_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --storage-account "$FUNC_STORAGE" \
  --flexconsumption-location "$LOCATION" \
  --runtime python \
  --runtime-version 3.11 \
  --functions-version 4 \
  -o none
echo "  作成完了"

# ========================================
# 12. Function App のアプリケーション設定
# ========================================
echo ""
echo "[12] Function App のアプリケーション設定..."

# Event Hub 互換エンドポイント接続文字列
EVENTHUB_CONN=$(az iot hub connection-string show \
  --hub-name "$IOTHUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --default-eventhub \
  --query connectionString -o tsv)

az functionapp config appsettings set \
  --name "$FUNC_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings \
    "IoTHubEventHubConnectionString=$EVENTHUB_CONN" \
    "IoTHubEventHubName=$IOTHUB_NAME" \
    "IoTHubConsumerGroup=functions-cg" \
    "ProcessedBlobConnectionString=$STORAGE_CONN_STR" \
    "ProcessedBlobAccountName=$STORAGE_ACCOUNT" \
    "ProcessedBlobContainerName=processed" \
    "LOGIC_APP_URL=" \
  -o none
echo "  アプリケーション設定完了"

# ========================================
# 13. 接続文字列取得
# ========================================
echo ""
echo "[13] 接続文字列取得..."

# デバイス接続文字列
ICU01_CONN=$(az iot hub device-identity connection-string show --hub-name "$IOTHUB_NAME" -g "$RESOURCE_GROUP" -d icu-device01 -o tsv --query connectionString)
ICU02_CONN=$(az iot hub device-identity connection-string show --hub-name "$IOTHUB_NAME" -g "$RESOURCE_GROUP" -d icu-device02 -o tsv --query connectionString)
GEN01_CONN=$(az iot hub device-identity connection-string show --hub-name "$IOTHUB_NAME" -g "$RESOURCE_GROUP" -d general-device01 -o tsv --query connectionString)
GEN02_CONN=$(az iot hub device-identity connection-string show --hub-name "$IOTHUB_NAME" -g "$RESOURCE_GROUP" -d general-device02 -o tsv --query connectionString)
GEN03_CONN=$(az iot hub device-identity connection-string show --hub-name "$IOTHUB_NAME" -g "$RESOURCE_GROUP" -d general-device03 -o tsv --query connectionString)

# IoT Hub サービス接続文字列
IOTHUB_CONN=$(az iot hub connection-string show --hub-name "$IOTHUB_NAME" -g "$RESOURCE_GROUP" --policy-name iothubowner -o tsv --query connectionString)

# ========================================
# 14. .env ファイル出力
# ========================================
ENV_FILE="$(dirname "$0")/../.env"
cat > "$ENV_FILE" << EOF
# Azure IoT Hub デモ環境 接続情報
# 生成日時: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# サブスクリプション: $(az account show --query name -o tsv)
# IoT Hub: $IOTHUB_NAME

# === デバイスシミュレータ用 ===
export ICU_DEVICE01_CONNECTION_STRING="$ICU01_CONN"
export ICU_DEVICE02_CONNECTION_STRING="$ICU02_CONN"
export GENERAL_DEVICE01_CONNECTION_STRING="$GEN01_CONN"
export GENERAL_DEVICE02_CONNECTION_STRING="$GEN02_CONN"
export GENERAL_DEVICE03_CONNECTION_STRING="$GEN03_CONN"

# === 管理アプリ用 ===
export IOTHUB_CONNECTION_STRING="$IOTHUB_CONN"

# === Functions ローカルデバッグ用 ===
export EVENTHUB_CONNECTION_STRING="$EVENTHUB_CONN"
export STORAGE_CONNECTION_STRING="$STORAGE_CONN_STR"

# === リソース名 ===
export IOTHUB_NAME="$IOTHUB_NAME"
export STORAGE_ACCOUNT="$STORAGE_ACCOUNT"
export FUNC_APP_NAME="$FUNC_APP_NAME"
export FUNC_STORAGE="$FUNC_STORAGE"
EOF

echo "  .env ファイルを出力しました: $ENV_FILE"

# ========================================
# 15. local.settings.json 更新
# ========================================
FUNC_DIR="$(dirname "$0")/../functions-app"
cat > "$FUNC_DIR/local.settings.json" << EOF
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",

    "IoTHubEventHubConnectionString": "$EVENTHUB_CONN",
    "IoTHubEventHubName": "$IOTHUB_NAME",
    "IoTHubConsumerGroup": "functions-cg",

    "ProcessedBlobConnectionString": "$STORAGE_CONN_STR",
    "ProcessedBlobAccountName": "$STORAGE_ACCOUNT",
    "ProcessedBlobContainerName": "processed",

    "LOGIC_APP_URL": ""
  }
}
EOF
echo "  local.settings.json を更新しました"

# ========================================
# 完了
# ========================================
echo ""
echo "==========================================="
echo " セットアップ完了!"
echo "==========================================="
echo ""
echo "  IoT Hub       : $IOTHUB_NAME"
echo "  Storage (data): $STORAGE_ACCOUNT"
echo "  Function App  : $FUNC_APP_NAME"
echo ""
echo "次のステップ:"
echo "  1. source .env"
echo "  2. cd device-simulator && python device_simulator.py icu-device01 telemetry"
echo "  3. cd functions-app && func start"
echo ""
