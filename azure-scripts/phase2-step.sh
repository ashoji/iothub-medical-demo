#!/bin/bash
# Phase 2 - Step by step execution
# Run each step individually

IOTHUB_NAME="<your-iothub-name>"
RESOURCE_GROUP="<your-resource-group>"
STORAGE_ACCOUNT="<your-storage-account>"
LOCATION="japaneast"
FUNC_APP_NAME="func-medical-demo"
LOG="/tmp/phase2_step.log"

> "$LOG"

step=$1

case "$step" in
  1)
    echo "Step 1: Consumer Group 確認/作成" | tee -a "$LOG"
    az iot hub consumer-group create \
      --hub-name "$IOTHUB_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --name functions-cg 2>&1 | tee -a "$LOG"
    echo "RC=$?" | tee -a "$LOG"
    ;;
  2)
    echo "Step 2: processed コンテナ作成" | tee -a "$LOG"
    az storage container create \
      --name processed \
      --account-name "$STORAGE_ACCOUNT" \
      --auth-mode login 2>&1 | tee -a "$LOG"
    echo "RC=$?" | tee -a "$LOG"
    ;;
  3)
    echo "Step 3: Functions用 Storage Account 作成" | tee -a "$LOG"
    FUNC_STORAGE="stfuncmedical$(date +%s | tail -c 10)"
    echo "FUNC_STORAGE=$FUNC_STORAGE" | tee -a "$LOG"
    az storage account create \
      --name "$FUNC_STORAGE" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --sku Standard_LRS 2>&1 | tee -a "$LOG"
    echo "RC=$?" | tee -a "$LOG"
    echo "$FUNC_STORAGE" > /tmp/func_storage_name.txt
    ;;
  4)
    echo "Step 4: Function App 作成" | tee -a "$LOG"
    FUNC_STORAGE=$(cat /tmp/func_storage_name.txt 2>/dev/null)
    echo "Using FUNC_STORAGE=$FUNC_STORAGE" | tee -a "$LOG"
    az functionapp create \
      --name "$FUNC_APP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --storage-account "$FUNC_STORAGE" \
      --flexconsumption-location "$LOCATION" \
      --runtime python \
      --runtime-version 3.11 \
      --functions-version 4 2>&1 | tee -a "$LOG"
    echo "RC=$?" | tee -a "$LOG"
    ;;
  5)
    echo "Step 5: 接続文字列取得 & アプリ設定" | tee -a "$LOG"
    EVENTHUB_CONN=$(az iot hub connection-string show \
      --hub-name "$IOTHUB_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --default-eventhub \
      --query connectionString -o tsv)
    echo "EventHub: ${EVENTHUB_CONN:0:60}..." | tee -a "$LOG"

    STORAGE_CONN=$(az storage account show-connection-string \
      --name "$STORAGE_ACCOUNT" \
      --resource-group "$RESOURCE_GROUP" \
      --query connectionString -o tsv)
    echo "Storage: ${STORAGE_CONN:0:60}..." | tee -a "$LOG"

    az functionapp config appsettings set \
      --name "$FUNC_APP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --settings \
        "IoTHubEventHubConnectionString=$EVENTHUB_CONN" \
        "IoTHubEventHubName=$IOTHUB_NAME" \
        "IoTHubConsumerGroup=functions-cg" \
        "ProcessedBlobConnectionString=$STORAGE_CONN" \
        "ProcessedBlobContainerName=processed" \
        "LOGIC_APP_URL=" 2>&1 | tee -a "$LOG"
    echo "RC=$?" | tee -a "$LOG"

    echo "" | tee -a "$LOG"
    echo "=== local.settings.json 用の値 ===" | tee -a "$LOG"
    echo "IoTHubEventHubConnectionString=$EVENTHUB_CONN" | tee -a "$LOG"
    echo "ProcessedBlobConnectionString=$STORAGE_CONN" | tee -a "$LOG"
    ;;
  *)
    echo "Usage: $0 {1|2|3|4|5}"
    ;;
esac
