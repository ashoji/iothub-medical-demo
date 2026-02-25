# Azure IoT Hub デモ環境セットアップ (PowerShell用)
# 
# このスクリプトは Azure リソースを自動作成します
#
# 【重要】PowerShell は管理者として実行してください
#
# 実行前の準備:
# 1. Azure CLI でログイン: az login
# 2. Azure IoT 拡張機能をインストール: az extension add --name azure-iot
#
# 実行方法:
# .\setup-resources.ps1

$ErrorActionPreference = "Stop"

# コマンド失敗時にスクリプトを停止する関数
function Assert-LastCommand {
    param([string]$Message)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] $Message (exit code: $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
}

# Azure IoT 拡張機能の確認
Write-Host "Azure IoT 拡張機能を確認しています..." -ForegroundColor Cyan
$iotExtension = az extension list --query "[?name=='azure-iot']" -o tsv
if ([string]::IsNullOrEmpty($iotExtension)) {
    Write-Host "Azure IoT 拡張機能をインストールしています..." -ForegroundColor Yellow
    az extension add --name azure-iot
    Write-Host "Azure IoT 拡張機能をインストールしました" -ForegroundColor Green
} else {
    Write-Host "Azure IoT 拡張機能は既にインストールされています" -ForegroundColor Green
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Azure IoT Hub デモ環境セットアップ" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# ========================================
# 0. リソースプロバイダーの登録
# ========================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "リソースプロバイダーの登録確認" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$providers = @("Microsoft.Devices", "Microsoft.Storage")
foreach ($provider in $providers) {
    $state = az provider show --namespace $provider --query "registrationState" -o tsv 2>$null
    if ($state -ne "Registered") {
        Write-Host "$provider を登録しています..." -ForegroundColor Yellow
        az provider register --namespace $provider | Out-Null
        Assert-LastCommand "$provider の登録に失敗しました"
        Write-Host "$provider の登録をリクエストしました。反映を待っています..." -ForegroundColor Yellow
        # 登録完了まで待機 (最大5分)
        $waitCount = 0
        do {
            Start-Sleep -Seconds 10
            $waitCount++
            $state = az provider show --namespace $provider --query "registrationState" -o tsv
            Write-Host "  状態: $state ($($waitCount * 10)秒経過)" -ForegroundColor Gray
        } while ($state -ne "Registered" -and $waitCount -lt 30)
        if ($state -ne "Registered") {
            Write-Host "[ERROR] $provider の登録がタイムアウトしました。Azure Portal で手動登録してください。" -ForegroundColor Red
            exit 1
        }
        Write-Host "$provider を登録しました" -ForegroundColor Green
    } else {
        Write-Host "$provider は登録済みです" -ForegroundColor Green
    }
}

# ========================================
# 1. 変数の設定
# ========================================

$RESOURCE_GROUP = "<your-resource-group>"
$LOCATION = "japaneast"
$TIMESTAMP = [int][double]::Parse((Get-Date -UFormat %s))
$IOTHUB_NAME = "iothub-medical-demo-$TIMESTAMP"
$STORAGE_ACCOUNT = "stmedical$($TIMESTAMP.ToString().Substring($TIMESTAMP.ToString().Length - 9))"
$SKU = "S1"

Write-Host ""
Write-Host "設定内容:" -ForegroundColor Yellow
Write-Host "  Resource Group: $RESOURCE_GROUP"
Write-Host "  Location: $LOCATION"
Write-Host "  IoT Hub Name: $IOTHUB_NAME"
Write-Host "  Storage Account: $STORAGE_ACCOUNT"
Write-Host "  SKU: $SKU"
Write-Host ""

$confirmation = Read-Host "この設定で続行しますか? (y/N)"
if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
    Write-Host "セットアップをキャンセルしました" -ForegroundColor Red
    exit 1
}

# ========================================
# 2. リソースグループの作成
# ========================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "リソースグループの作成" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$exists = az group exists --name $RESOURCE_GROUP
if ($exists -eq "false") {
    Write-Host "リソースグループを作成しています..." -ForegroundColor Yellow
    az group create --name $RESOURCE_GROUP --location $LOCATION | Out-Null
    Assert-LastCommand "リソースグループの作成に失敗しました"
    Write-Host "リソースグループを作成しました" -ForegroundColor Green
} else {
    Write-Host "リソースグループは既に存在します" -ForegroundColor Green
}

# ========================================
# 3. ストレージアカウントの作成
# ========================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "ストレージアカウントの作成" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "ストレージアカウントを作成しています..." -ForegroundColor Yellow
az storage account create `
  --name $STORAGE_ACCOUNT `
  --resource-group $RESOURCE_GROUP `
  --location $LOCATION `
  --sku Standard_LRS `
  --kind StorageV2 `
  --allow-blob-public-access false | Out-Null
Assert-LastCommand "ストレージアカウントの作成に失敗しました"

Write-Host "ストレージアカウントを作成しました" -ForegroundColor Green

# ネットワークルールの設定（すべてのネットワークからアクセス許可）
Write-Host "ネットワークルールを設定しています..." -ForegroundColor Yellow
az storage account update `
  --name $STORAGE_ACCOUNT `
  --resource-group $RESOURCE_GROUP `
  --default-action Allow | Out-Null

# 現在のユーザーにロールを割り当て
Write-Host "ユーザーにロールを割り当てています..." -ForegroundColor Yellow
$USER_OBJECT_ID = az ad signed-in-user show --query id -o tsv
$STORAGE_ID = az storage account show `
  --name $STORAGE_ACCOUNT `
  --resource-group $RESOURCE_GROUP `
  --query id -o tsv

az role assignment create `
  --assignee $USER_OBJECT_ID `
  --role "Storage Blob Data Contributor" `
  --scope $STORAGE_ID 2>$null | Out-Null

# ロール割り当てが反映されるまで待機
Write-Host "ロール割り当ての反映を待っています..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# Blobコンテナの作成
Write-Host "Blobコンテナを作成しています..." -ForegroundColor Yellow
az storage container create `
  --name image `
  --account-name $STORAGE_ACCOUNT `
  --auth-mode login | Out-Null

az storage container create `
  --name telemetry `
  --account-name $STORAGE_ACCOUNT `
  --auth-mode login | Out-Null

Write-Host "Blobコンテナを作成しました (image, telemetry)" -ForegroundColor Green

# ========================================
# 4. IoT Hub の作成
# ========================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "IoT Hub の作成" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "IoT Hub を作成しています (数分かかります)..." -ForegroundColor Yellow
az iot hub create `
  --name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --location $LOCATION `
  --sku $SKU `
  --partition-count 2 | Out-Null
Assert-LastCommand "IoT Hub の作成に失敗しました"

Write-Host "IoT Hub を作成しました" -ForegroundColor Green

# ========================================
# 5. Managed Identity の設定
# ========================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Managed Identity の設定" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "Managed Identity を有効化しています..." -ForegroundColor Yellow
az iot hub identity assign `
  --name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --system-assigned | Out-Null
Assert-LastCommand "Managed Identity の有効化に失敗しました"

# Principal ID取得
$PRINCIPAL_ID = az iot hub identity show `
  --name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --query principalId -o tsv

Write-Host "Principal ID: $PRINCIPAL_ID"

# ストレージアカウントID取得
$STORAGE_ID = az storage account show `
  --name $STORAGE_ACCOUNT `
  --resource-group $RESOURCE_GROUP `
  --query id -o tsv

Write-Host "ロール割り当てを設定しています..." -ForegroundColor Yellow
az role assignment create `
  --assignee $PRINCIPAL_ID `
  --role "Storage Blob Data Contributor" `
  --scope $STORAGE_ID | Out-Null

Write-Host "Managed Identity を設定しました" -ForegroundColor Green

# ========================================
# 6. デバイスの登録
# ========================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "デバイスの登録" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "デバイスを登録しています..." -ForegroundColor Yellow
az iot hub device-identity create --hub-name $IOTHUB_NAME --resource-group $RESOURCE_GROUP --device-id icu-device01 | Out-Null
az iot hub device-identity create --hub-name $IOTHUB_NAME --resource-group $RESOURCE_GROUP --device-id icu-device02 | Out-Null
az iot hub device-identity create --hub-name $IOTHUB_NAME --resource-group $RESOURCE_GROUP --device-id general-device01 | Out-Null
az iot hub device-identity create --hub-name $IOTHUB_NAME --resource-group $RESOURCE_GROUP --device-id general-device02 | Out-Null
az iot hub device-identity create --hub-name $IOTHUB_NAME --resource-group $RESOURCE_GROUP --device-id general-device03 | Out-Null

Write-Host "5つのデバイスを登録しました (ICU: icu-device01, icu-device02 / 一般病棟: general-device01-03)" -ForegroundColor Green

# ========================================
# 7. メッセージルーティング設定
# ========================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "メッセージルーティング設定" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# ストレージコンテナURI取得
$STORAGE_CONTAINER_URI = "https://$STORAGE_ACCOUNT.blob.core.windows.net/telemetry"

Write-Host "カスタムエンドポイントを作成しています..." -ForegroundColor Yellow
$subscriptionId = az account show --query id -o tsv

try {
    az iot hub message-endpoint create storage-container `
      --hub-name $IOTHUB_NAME `
      --resource-group $RESOURCE_GROUP `
      --endpoint-name BlobStorageEndpoint `
      --endpoint-resource-group $RESOURCE_GROUP `
      --endpoint-subscription-id $subscriptionId `
      --endpoint-uri "https://$STORAGE_ACCOUNT.blob.core.windows.net" `
      --container telemetry `
      --encoding json `
      --file-name-format '{iothub}/{partition}/{YYYY}/{MM}/{DD}/{HH}/{mm}.json' `
      --identity "[system]" 2>$null | Out-Null
} catch {
    Write-Host "警告: Managed Identity でのエンドポイント作成に失敗しました" -ForegroundColor Yellow
    Write-Host "接続文字列ベースの認証にフォールバックします..." -ForegroundColor Yellow
    
    $STORAGE_CONNECTION_STRING = az storage account show-connection-string `
      --name $STORAGE_ACCOUNT `
      --resource-group $RESOURCE_GROUP `
      --query connectionString -o tsv
    
    az iot hub message-endpoint create storage-container `
      --hub-name $IOTHUB_NAME `
      --resource-group $RESOURCE_GROUP `
      --endpoint-name BlobStorageEndpoint `
      --connection-string $STORAGE_CONNECTION_STRING `
      --container telemetry `
      --encoding json `
      --file-name-format '{iothub}/{partition}/{YYYY}/{MM}/{DD}/{HH}/{mm}.json' | Out-Null
}

Write-Host "ルーティングルールを作成しています..." -ForegroundColor Yellow
az iot hub message-route create `
  --hub-name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --route-name TelemetryRoute `
  --endpoint-name BlobStorageEndpoint `
  --source devicemessages `
  --enabled true | Out-Null

Write-Host "メッセージルーティングを設定しました" -ForegroundColor Green

# ========================================
# 8. ファイルアップロード設定
# ========================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "ファイルアップロード設定" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "ファイルアップロード設定を構成しています (Managed Identity 使用)..." -ForegroundColor Yellow

# Storage接続文字列を取得（Managed Identity使用時も必要）
$STORAGE_CONNECTION_STRING = az storage account show-connection-string `
  --name $STORAGE_ACCOUNT `
  --resource-group $RESOURCE_GROUP `
  --query connectionString -o tsv

az iot hub update `
  --name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --fileupload-storage-connectionstring $STORAGE_CONNECTION_STRING `
  --fileupload-storage-container-name image `
  --fileupload-storage-auth-type identityBased `
  --fileupload-storage-identity "[system]" | Out-Null

Write-Host "ファイルアップロード設定を完了しました (Managed Identity)" -ForegroundColor Green

# ========================================
# 9. 接続文字列の取得と表示
# ========================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "セットアップ完了" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "以下の環境変数を設定してください:" -ForegroundColor Yellow
Write-Host ""

# ICUデバイス接続文字列
$ICU_DEVICE01_CONN = az iot hub device-identity connection-string show `
  --hub-name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --device-id icu-device01 `
  --query connectionString -o tsv

$ICU_DEVICE02_CONN = az iot hub device-identity connection-string show `
  --hub-name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --device-id icu-device02 `
  --query connectionString -o tsv

# 一般病棟デバイス接続文字列
$GENERAL_DEVICE01_CONN = az iot hub device-identity connection-string show `
  --hub-name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --device-id general-device01 `
  --query connectionString -o tsv

$GENERAL_DEVICE02_CONN = az iot hub device-identity connection-string show `
  --hub-name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --device-id general-device02 `
  --query connectionString -o tsv

$GENERAL_DEVICE03_CONN = az iot hub device-identity connection-string show `
  --hub-name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --device-id general-device03 `
  --query connectionString -o tsv

# IoT Hub接続文字列
$IOTHUB_CONN = az iot hub connection-string show `
  --hub-name $IOTHUB_NAME `
  --resource-group $RESOURCE_GROUP `
  --policy-name iothubowner `
  --query connectionString -o tsv

Write-Host "# PowerShell用 (ICUデバイスシミュレータ用)" -ForegroundColor Cyan
Write-Host "`$env:ICU_DEVICE01_CONNECTION_STRING=`"$ICU_DEVICE01_CONN`""
Write-Host "`$env:ICU_DEVICE02_CONNECTION_STRING=`"$ICU_DEVICE02_CONN`""
Write-Host ""
Write-Host "# PowerShell用 (一般病棟デバイスシミュレータ用)" -ForegroundColor Cyan
Write-Host "`$env:GENERAL_DEVICE01_CONNECTION_STRING=`"$GENERAL_DEVICE01_CONN`""
Write-Host "`$env:GENERAL_DEVICE02_CONNECTION_STRING=`"$GENERAL_DEVICE02_CONN`""
Write-Host "`$env:GENERAL_DEVICE03_CONNECTION_STRING=`"$GENERAL_DEVICE03_CONN`""
Write-Host ""
Write-Host "# PowerShell用 (管理アプリ用)" -ForegroundColor Cyan
Write-Host "`$env:IOTHUB_CONNECTION_STRING=`"$IOTHUB_CONN`""
Write-Host ""

# 環境変数をファイルに保存
# Cloud Shell / WSL 対応: スクリプトと同じディレクトリに保存
if ($PSScriptRoot) {
    $envFilePath = Join-Path (Split-Path -Parent $PSScriptRoot) ".env.ps1"
} else {
    $envFilePath = Join-Path $HOME ".env.ps1"
}

@"
# Azure IoT Hub 接続情報 (PowerShell用)
# このファイルを読み込んでください: . .\.env.ps1

# ICUデバイス接続文字列 (デバイスシミュレータ用)
`$env:ICU_DEVICE01_CONNECTION_STRING="$ICU_DEVICE01_CONN"
`$env:ICU_DEVICE02_CONNECTION_STRING="$ICU_DEVICE02_CONN"

# 一般病棟デバイス接続文字列 (デバイスシミュレータ用)
`$env:GENERAL_DEVICE01_CONNECTION_STRING="$GENERAL_DEVICE01_CONN"
`$env:GENERAL_DEVICE02_CONNECTION_STRING="$GENERAL_DEVICE02_CONN"
`$env:GENERAL_DEVICE03_CONNECTION_STRING="$GENERAL_DEVICE03_CONN"

# IoT Hub接続文字列 (管理アプリ用)
`$env:IOTHUB_CONNECTION_STRING="$IOTHUB_CONN"

Write-Host "環境変数を設定しました" -ForegroundColor Green
"@ | Out-File -FilePath $envFilePath -Encoding UTF8

Write-Host "接続文字列を $envFilePath に保存しました" -ForegroundColor Green
Write-Host ""
Write-Host "環境変数を読み込むには以下のコマンドを実行してください:" -ForegroundColor Yellow
Write-Host "  . .\.env.ps1"
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "セットアップが完了しました！" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
