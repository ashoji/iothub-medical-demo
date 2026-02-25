/*
 * Azure IoT Hub デバイスシミュレータ
 * 医療機器を想定したテレメトリ送信と画像アップロード機能
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>
#include <iothub.h>
#include <iothub_device_client.h>
#include <iothub_client_options.h>
#include <iothub_message.h>
#include <iothubtransportmqtt.h>
#include <azure_c_shared_utility/threadapi.h>
#include <azure_c_shared_utility/crt_abstractions.h>
#include <azure_c_shared_utility/shared_util_options.h>

// ANSI カラーコード
#define COLOR_RED     "\033[0;31m"
#define COLOR_GREEN   "\033[0;32m"
#define COLOR_YELLOW  "\033[0;33m"
#define COLOR_RESET   "\033[0m"

// グローバル変数
static volatile bool g_continueRunning = true;
static volatile bool g_uploadCompleted = false;
static IOTHUB_DEVICE_CLIENT_HANDLE g_deviceClientHandle = NULL;

// シグナルハンドラ（Ctrl+C での終了）
void signalHandler(int signal)
{
    if (signal == SIGINT)
    {
        printf("\n[INFO] Interrupt signal received. Shutting down...\n");
        g_continueRunning = false;
    }
}

// Cloud-to-Device メッセージ受信コールバック
static IOTHUBMESSAGE_DISPOSITION_RESULT receiveMessageCallback(
    IOTHUB_MESSAGE_HANDLE message,
    void* userContextCallback)
{
    (void)userContextCallback;
    // メッセージ ID
    const char* messageId = IoTHubMessage_GetMessageId(message);
    // クラウド～デバイス間でメッセージを関連づける ID
    const char* correlationId = IoTHubMessage_GetCorrelationId(message);
    
    const unsigned char* buffer = NULL;
    size_t size = 0;
    
    if (IoTHubMessage_GetByteArray(message, &buffer, &size) != IOTHUB_MESSAGE_OK)
    {
        printf("[ERROR] Failed to retrieve message content\n");
        return IOTHUBMESSAGE_REJECTED;
    }
    
    printf("\n" COLOR_RED "========================================\n");
    printf("[C2D] Cloud-to-Device message received\n");
    printf("========================================" COLOR_RESET "\n");
    if (messageId != NULL)
    {
        printf(COLOR_RED "Message ID: %s" COLOR_RESET "\n", messageId);
    }
    if (correlationId != NULL)
    {
        printf(COLOR_RED "Correlation ID: %s" COLOR_RESET "\n", correlationId);
    }
    printf(COLOR_RED "Message content:\n%.*s" COLOR_RESET "\n", (int)size, buffer);
    printf(COLOR_RED "========================================" COLOR_RESET "\n\n");
    
    return IOTHUBMESSAGE_ACCEPTED;
}

// メッセージ送信確認コールバック
static void sendConfirmationCallback(
    IOTHUB_CLIENT_CONFIRMATION_RESULT result,
    void* userContextCallback)
{
    (void)userContextCallback;
    
    if (result == IOTHUB_CLIENT_CONFIRMATION_OK)
    {
        printf("[OK] Message sent successfully\n");
    }
    else
    {
        printf("[ERROR] Message send failed: %d\n", result);
    }
}

// 接続ステータス変更コールバック
static void connectionStatusCallback(
    IOTHUB_CLIENT_CONNECTION_STATUS result,
    IOTHUB_CLIENT_CONNECTION_STATUS_REASON reason,
    void* userContextCallback)
{
    (void)userContextCallback;  // 未使用パラメータの警告抑制
    
    if (result == IOTHUB_CLIENT_CONNECTION_AUTHENTICATED)
    {
        printf("[INFO] Connected to IoT Hub (Reason: %d)\n", reason);
    }
    else
    {
        printf("[WARNING] Disconnected from IoT Hub (Reason: %d)\n", reason);
    }
}

// ファイルアップロード完了コールバック
static void fileUploadCallback(
    IOTHUB_CLIENT_FILE_UPLOAD_RESULT result,
    void* userContextCallback)
{
    (void)userContextCallback; // 未使用パラメータの警告抑制
    
    if (result == FILE_UPLOAD_OK)
    {
        printf("[OK] File upload completed successfully\n");
    }
    else
    {
        printf("[ERROR] File upload failed with result: %d\n", result);
    }
    
    // アップロード完了フラグを設定
    g_uploadCompleted = true;
}

// 医療機器テレメトリデータの生成
void generateMedicalTelemetry(char* jsonBuffer, size_t bufferSize, const char* deviceId)
{
    // 現在時刻の取得
    time_t now = time(NULL);
    struct tm* timeinfo = gmtime(&now);
    char timestamp[32];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%SZ", timeinfo);
    
    // 医療機器データのシミュレーション
    int heartRate = 60 + (rand() % 40);                      // 脈拍: 60-100 bpm
    int bloodPressureSystolic = 110 + (rand() % 30);         // 収縮期血圧: 110-140 mmHg
    int bloodPressureDiastolic = 70 + (rand() % 20);         // 拡張期血圧: 70-90 mmHg
    double bodyTemperature = 36.0 + (rand() % 20) / 10.0;    // 体温: 36.0-38.0 °C
    int spo2 = 95 + (rand() % 6);                            // 酸素飽和度: 95-100%
    double respiratoryRate = 12.0 + (rand() % 80) / 10.0;    // 呼吸数: 12.0-20.0 回/分
    
    // ステータス判定
    const char* status = "normal";
    if (heartRate > 100 || bodyTemperature > 37.5 || spo2 < 95)
    {
        status = "warning";
    }
    if (heartRate > 120 || bodyTemperature > 38.5 || spo2 < 90)
    {
        status = "critical";
    }
    
    // JSON形式で生成
    snprintf(jsonBuffer, bufferSize,
        "{"
        "\"deviceId\":\"%s\","
        "\"timestamp\":\"%s\","
        "\"heartRate\":%d,"
        "\"bloodPressureSystolic\":%d,"
        "\"bloodPressureDiastolic\":%d,"
        "\"bodyTemperature\":%.1f,"
        "\"spo2\":%d,"
        "\"respiratoryRate\":%.1f,"
        "\"patientStatus\":\"%s\""
        "}",
        deviceId, timestamp, heartRate,
        bloodPressureSystolic, bloodPressureDiastolic,
        bodyTemperature, spo2, respiratoryRate, status
    );
}

// テレメトリ送信モード
int runTelemetryMode(const char* deviceId, int intervalMs)
{
    char jsonBuffer[512];
    int messageCount = 0;
    
    printf("[INFO] Starting telemetry mode\n");
    printf("[INFO] Device ID: %s\n", deviceId);
    printf("[INFO] Interval: %d ms\n", intervalMs);
    printf("[INFO] Press Ctrl+C to stop\n\n");
    
    while (g_continueRunning)
    {
        // テレメトリデータ生成
        generateMedicalTelemetry(jsonBuffer, sizeof(jsonBuffer), deviceId);
        
        // メッセージの作成
        IOTHUB_MESSAGE_HANDLE messageHandle = IoTHubMessage_CreateFromString(jsonBuffer);
        if (messageHandle == NULL)
        {
            printf("[ERROR] Failed to create message\n");
            continue;
        }
        
        // メッセージプロパティの設定
        (void)IoTHubMessage_SetContentTypeSystemProperty(messageHandle, "application/json");
        (void)IoTHubMessage_SetContentEncodingSystemProperty(messageHandle, "utf-8");
        
        // メッセージ送信
        printf("[%d] Sending telemetry...\n", ++messageCount);
        printf(COLOR_GREEN "    Data: %s" COLOR_RESET "\n", jsonBuffer);
        
        IOTHUB_CLIENT_RESULT result = IoTHubDeviceClient_SendEventAsync(
            g_deviceClientHandle,
            messageHandle,
            sendConfirmationCallback,
            NULL
        );
        
        if (result != IOTHUB_CLIENT_OK)
        {
            printf("[ERROR] Failed to send message: %d\n", result);
        }
        
        IoTHubMessage_Destroy(messageHandle);
        
        // Device to Cloud メッセージのインターバル待機
        ThreadAPI_Sleep(intervalMs);
    }
    
    printf("\n[INFO] Telemetry mode stopped. Total messages sent: %d\n", messageCount);
    return 0;
}

// 画像アップロードモード
int runUploadMode(const char* deviceId, const char* filePath)
{
    printf("[INFO] Starting upload mode\n");
    printf("[INFO] Device ID: %s\n", deviceId);
    printf("[INFO] File path: %s\n", filePath);
    
    // ファイルの存在確認
    struct stat st;
    if (stat(filePath, &st) != 0)
    {
        printf("[ERROR] File not found: %s\n", filePath);
        return 1;
    }
    
    printf("[INFO] File size: %ld bytes\n", st.st_size);
    
    // ファイル読み込み
    FILE* file = fopen(filePath, "rb");
    if (file == NULL)
    {
        printf("[ERROR] Failed to open file: %s\n", filePath);
        return 1;
    }
    
    // ファイル内容をメモリに読み込み
    unsigned char* fileContent = (unsigned char*)malloc(st.st_size);
    if (fileContent == NULL)
    {
        printf("[ERROR] Memory allocation failed\n");
        fclose(file);
        return 1;
    }
    
    size_t bytesRead = fread(fileContent, 1, st.st_size, file);
    fclose(file);
    
    if (bytesRead != (size_t)st.st_size)
    {
        printf("[ERROR] Failed to read complete file\n");
        free(fileContent);
        return 1;
    }
    
    printf("[INFO] File loaded into memory\n");
    
    // ファイル名の抽出
    const char* fileName = strrchr(filePath, '/');
    fileName = (fileName == NULL) ? filePath : fileName + 1;
    
    // タイムスタンプ付きファイル名の生成 (yyyymmddhhmmss)
    time_t now = time(NULL);
    struct tm* timeinfo = gmtime(&now);
    char timestamp[16];
    strftime(timestamp, sizeof(timestamp), "%Y%m%d%H%M%S", timeinfo);
    
    char destFileName[256];
    snprintf(destFileName, sizeof(destFileName), "%s_%s_%s", 
             deviceId, timestamp, fileName);
    
    printf("[INFO] Uploading file as: %s\n", destFileName);
    printf("[INFO] Upload in progress...\n");
    
    // ファイルアップロード
    IOTHUB_CLIENT_RESULT result = IoTHubDeviceClient_UploadToBlobAsync(
        g_deviceClientHandle,
        destFileName,
        fileContent,
        st.st_size,
        fileUploadCallback,
        NULL
    );
    
    if (result != IOTHUB_CLIENT_OK)
    {
        printf("[ERROR] Failed to initiate file upload: %d\n", result);
        free(fileContent);
        return 1;
    }
    
    // アップロード完了待機
    int timeout = 60; // 60秒タイムアウト
    g_uploadCompleted = false; // フラグ初期化
    
    while (timeout > 0 && g_continueRunning && !g_uploadCompleted)
    {
        // 待機
        ThreadAPI_Sleep(1000);
        timeout--;
        
        if (timeout % 10 == 0)
        {
            printf("[INFO] Waiting for upload completion... (%d seconds remaining)\n", timeout);
        }
    }
    
    free(fileContent);
    
    if (!g_uploadCompleted && timeout == 0)
    {
        printf("[WARNING] Upload timeout\n");
        return 1;
    }
    
    printf("[INFO] Upload mode completed\n");
    return 0;
}

// メイン関数
int main(int argc, char* argv[])
{
    // 引数チェック
    if (argc < 3)
    {
        printf("Usage:\n");
        printf("  Telemetry mode: %s <device_name> telemetry [interval_ms]\n", argv[0]);
        printf("  Upload mode:    %s <device_name> upload <file_path>\n", argv[0]);
        printf("\n");
        printf("Examples:\n");
        printf("  %s device01 telemetry 5000\n", argv[0]);
        printf("  %s device01 upload /path/to/image.jpg\n", argv[0]);
        return 1;
    }
    
    const char* deviceName = argv[1];
    const char* mode = argv[2];
    
    // 環境変数から接続文字列取得
    char envVarName[64];
    snprintf(envVarName, sizeof(envVarName), "%s_CONNECTION_STRING", deviceName);
    
    // 大文字に変換し、ハイフンをアンダースコアに置換
    for (int i = 0; envVarName[i]; i++)
    {
        if (envVarName[i] >= 'a' && envVarName[i] <= 'z')
        {
            envVarName[i] = envVarName[i] - 'a' + 'A';
        }
        else if (envVarName[i] == '-')
        {
            envVarName[i] = '_';
        }
    }
    
    const char* connectionString = getenv(envVarName);
    if (connectionString == NULL)
    {
        printf("[ERROR] Environment variable not set: %s\n", envVarName);
        printf("Please set it using:\n");
        printf("export %s=\"HostName=...\"\n", envVarName);
        return 1;
    }
    
    printf("===========================================\n");
    printf(" Azure IoT Hub Device Simulator\n");
    printf("===========================================\n");
    printf("Device: %s\n", deviceName);
    printf("Mode: %s\n", mode);
    printf("===========================================\n\n");
    
    // シグナルハンドラ設定
    signal(SIGINT, signalHandler);
    
    // 乱数シード初期化
    srand(time(NULL));
    
    // IoT Hub SDK 初期化
    if (IoTHub_Init() != 0)
    {
        printf("[ERROR] Failed to initialize IoT Hub SDK\n");
        return 1;
    }
    
    // デバイスクライアント作成
    g_deviceClientHandle = IoTHubDeviceClient_CreateFromConnectionString(
        connectionString,
        MQTT_Protocol
    );
    
    if (g_deviceClientHandle == NULL)
    {
        printf("[ERROR] Failed to create device client\n");
        IoTHub_Deinit();
        return 1;
    }
    
    printf("[INFO] Device client created successfully\n");
    
    // オプション設定
    bool traceOn = false;
    IoTHubDeviceClient_SetOption(g_deviceClientHandle, OPTION_LOG_TRACE, &traceOn);
    
    // コールバック設定
    IoTHubDeviceClient_SetMessageCallback(g_deviceClientHandle, receiveMessageCallback, NULL);
    IoTHubDeviceClient_SetConnectionStatusCallback(g_deviceClientHandle, connectionStatusCallback, NULL);
    
    int exitCode = 0;
    
    // モード判定と実行
    if (strcmp(mode, "telemetry") == 0)
    {
        int intervalMs = 5000; // デフォルト5秒
        if (argc >= 4)
        {
            intervalMs = atoi(argv[3]);
            if (intervalMs <= 0)
            {
                intervalMs = 5000;
            }
        }
        exitCode = runTelemetryMode(deviceName, intervalMs);
    }
    else if (strcmp(mode, "upload") == 0)
    {
        if (argc < 4)
        {
            printf("[ERROR] File path required for upload mode\n");
            exitCode = 1;
        }
        else
        {
            exitCode = runUploadMode(deviceName, argv[3]);
        }
    }
    else
    {
        printf("[ERROR] Unknown mode: %s\n", mode);
        printf("Valid modes: telemetry, upload\n");
        exitCode = 1;
    }
    
    // クリーンアップ
    printf("\n[INFO] Cleaning up...\n");
    IoTHubDeviceClient_Destroy(g_deviceClientHandle);
    IoTHub_Deinit();
    
    printf("[INFO] Device simulator terminated\n");
    return exitCode;
}
