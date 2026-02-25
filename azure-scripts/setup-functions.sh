#!/bin/bash
# Phase 2: Azure リソース準備スクリプト (Managed Identity 版)
# テナントポリシーで allowSharedKeyAccess=false が強制されるため、
# すべての接続をマネージド ID ベースで構成する。
set -e

IOTHUB_NAME="<your-iothub-name>"
RESOURCE_GROUP="<your-resource-group>"
STORAGE_ACCOUNT="<your-storage-account>"
LOCATION="japaneast"
SUBSCRIPTION_ID="<your-subscription-id>"
FUNC_APP_NAME="func-medical-demo"

echo "=== Phase 2: Azure リソース準備 (Managed Identity) ==="

# 2-1: コンシューマグループ作成
echo ""
echo "[2-1] コンシューマグループ functions-cg を作成..."
az iot hub consumer-group create \
  --hub-name "$IOTHUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --name functions-cg -o json 2>&1 || echo "[SKIP] 既に存在する可能性あり"
echo "[2-1] 完了"

# 2-2: processed コンテナ作成
echo ""
echo "[2-2] processed コンテナを作成..."
az storage container create \
  --name processed \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login -o json 2>&1 || echo "[SKIP] 既に存在する可能性あり"
echo "[2-2] 完了"

# 2-3: Function App 用 Storage Account 作成
FUNC_STORAGE="stfuncmedical$(date +%s | tail -c 10)"
echo ""
echo "[2-3] Functions 用 Storage Account を作成: $FUNC_STORAGE"
az storage account create \
  --name "$FUNC_STORAGE" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  -o json 2>&1 | tail -3
echo "[2-3] 完了"

# 2-4: Consumption Plan (Y1) を ARM REST API で作成
ASP_NAME="ASP-medical-demo"
echo ""
echo "[2-4a] App Service Plan (Y1 Dynamic) を作成: $ASP_NAME"
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/serverfarms/$ASP_NAME?api-version=2023-12-01" \
  --body "{\"location\":\"$LOCATION\",\"kind\":\"linux\",\"sku\":{\"name\":\"Y1\",\"tier\":\"Dynamic\"},\"properties\":{\"reserved\":true}}" \
  -o none 2>&1
echo "[2-4a] 完了"

# Function App を ARM REST API で作成 (MI + identity-based storage)
# CLI の az functionapp create はファイルシェア作成時に共有キーを使うため、
# テナントポリシー下では 403 で失敗する。ARM API で直接作成して回避。
echo ""
echo "[2-4b] Function App を作成: $FUNC_APP_NAME (MI + identity-based storage)"
cat > /tmp/func-arm-body.json << EOF
{
  "location": "$LOCATION",
  "kind": "functionapp,linux",
  "identity": {"type": "SystemAssigned"},
  "properties": {
    "serverFarmId": "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/serverfarms/$ASP_NAME",
    "reserved": true,
    "siteConfig": {
      "linuxFxVersion": "Python|3.11",
      "appSettings": [
        {"name": "FUNCTIONS_EXTENSION_VERSION", "value": "~4"},
        {"name": "FUNCTIONS_WORKER_RUNTIME", "value": "python"},
        {"name": "AzureWebJobsStorage__accountName", "value": "$FUNC_STORAGE"},
        {"name": "WEBSITE_RUN_FROM_PACKAGE", "value": "1"}
      ]
    }
  }
}
EOF
RESP=$(az rest --method PUT \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNC_APP_NAME?api-version=2023-12-01" \
  --body @/tmp/func-arm-body.json 2>&1)
PRINCIPAL_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['identity']['principalId'])" 2>/dev/null)
echo "Function App Principal ID: $PRINCIPAL_ID"
echo "[2-4b] 完了"

# 2-5: RBAC ロール割り当て (Managed Identity)
echo ""
echo "[2-5] RBAC ロール割り当て..."
FUNC_STORAGE_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$FUNC_STORAGE"
MED_STORAGE_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"
IOTHUB_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Devices/IotHubs/$IOTHUB_NAME"

# Functions Storage ロール (ランタイム用)
az role assignment create --assignee "$PRINCIPAL_ID" --role "Storage Blob Data Owner" --scope "$FUNC_STORAGE_SCOPE" -o none 2>&1
echo "  [OK] Storage Blob Data Owner (Functions Storage)"
az role assignment create --assignee "$PRINCIPAL_ID" --role "Storage Account Contributor" --scope "$FUNC_STORAGE_SCOPE" -o none 2>&1
echo "  [OK] Storage Account Contributor (Functions Storage)"
az role assignment create --assignee "$PRINCIPAL_ID" --role "Storage Queue Data Contributor" --scope "$FUNC_STORAGE_SCOPE" -o none 2>&1
echo "  [OK] Storage Queue Data Contributor (Functions Storage)"
az role assignment create --assignee "$PRINCIPAL_ID" --role "Storage Table Data Contributor" --scope "$FUNC_STORAGE_SCOPE" -o none 2>&1
echo "  [OK] Storage Table Data Contributor (Functions Storage)"

# Medical Storage ロール (processed Blob 出力用)
az role assignment create --assignee "$PRINCIPAL_ID" --role "Storage Blob Data Contributor" --scope "$MED_STORAGE_SCOPE" -o none 2>&1
echo "  [OK] Storage Blob Data Contributor (Medical Storage)"

# IoT Hub ロール (EventHub トリガー読み取り用)
az role assignment create --assignee "$PRINCIPAL_ID" --role "Azure Event Hubs Data Receiver" --scope "$IOTHUB_SCOPE" -o none 2>&1
echo "  [OK] Azure Event Hubs Data Receiver (IoT Hub)"
echo "[2-5] 完了"

# 2-6: EventHub 互換エンドポイントの名前空間を取得 (MI 用)
echo ""
echo "[2-6] EventHub 互換エンドポイント名前空間を取得..."
EVENTHUB_ENDPOINT=$(az iot hub show --name "$IOTHUB_NAME" --resource-group "$RESOURCE_GROUP" \
  --query "properties.eventHubEndpoints.events.endpoint" -o tsv 2>&1)
# sb://xxx.servicebus.windows.net/ から FQDN を抽出
EVENTHUB_FQDN=$(echo "$EVENTHUB_ENDPOINT" | sed 's|sb://||;s|/||;s|:.*||')
echo "EventHub FQDN: $EVENTHUB_FQDN"
echo "[2-6] 完了"

# 2-7: Function App のアプリ設定 (全て MI ベース、接続文字列なし)
echo ""
echo "[2-7] Function App のアプリ設定を登録 (Managed Identity)..."
az functionapp config appsettings set \
  --name "$FUNC_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings \
    "IoTHubEventHubConnectionString__fullyQualifiedNamespace=$EVENTHUB_FQDN" \
    "IoTHubEventHubName=$IOTHUB_NAME" \
    "IoTHubConsumerGroup=functions-cg" \
    "ProcessedBlobAccountName=$STORAGE_ACCOUNT" \
    "ProcessedBlobContainerName=processed" \
    "LOGIC_APP_URL=" \
  -o none 2>&1
echo "[2-7] 完了"

echo ""
echo "=== Phase 2 完了 (Managed Identity) ==="
echo ""
echo "Functions 用 Storage: $FUNC_STORAGE"
echo "Function App: $FUNC_APP_NAME"
echo "Principal ID: $PRINCIPAL_ID"
echo ""
echo "EventHub FQDN: $EVENTHUB_FQDN"
echo ""
echo "※ 接続文字列は一切使用していません (Managed Identity のみ)"
