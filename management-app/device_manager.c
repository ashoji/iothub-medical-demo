/*
 * Azure IoT Hub 管理アプリケーション (C言語版)
 * Cloud-to-Device メッセージ送信機能
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <iothub_service_client_auth.h>
#include <iothub_messaging.h>
#include <azure_c_shared_utility/threadapi.h>
#include <azure_c_shared_utility/crt_abstractions.h>
#include <iothub_registrymanager.h>

// グローバル変数
static volatile int g_messageCount = 0;

// メッセージ送信確認コールバック
static void messageSendCallback(void* context, IOTHUB_MESSAGING_RESULT messagingResult)
{
    (void)context;
    
    if (messagingResult == IOTHUB_MESSAGING_OK)
    {
        printf("[OK] Message sent successfully\n");
    }
    else
    {
        printf("[ERROR] Message send failed: %d\n", messagingResult);
    }
    
    g_messageCount++;
}

// C2Dメッセージの作成
void createMedicalCommand(char* jsonBuffer, size_t bufferSize, const char* deviceId)
{
    (void)deviceId;

    time_t now = time(NULL);
    struct tm* timeinfo = gmtime(&now);
    char timestamp[32];
    char messageId[64];
    
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%SZ", timeinfo);
    snprintf(messageId, sizeof(messageId), "msg-%ld", now);

    // request_diagnostic_data 固定
    snprintf(jsonBuffer, bufferSize,
        "{"
        "\"messageId\":\"%s\","
        "\"timestamp\":\"%s\","
        "\"command\":\"request_diagnostic_data\","
        "\"description\":\"診断データの要求\","
        "\"parameters\":{"
            "\"include_logs\":true,"
            "\"time_range_hours\":24"
        "},"
        "\"sender\":\"management-app-c\","
        "\"priority\":\"normal\""
        "}",
        messageId, timestamp);
}

// デバイスへメッセージ送信
int sendMessageToDevice(IOTHUB_MESSAGING_CLIENT_HANDLE messagingHandle, const char* deviceId)
{
    char messageBuffer[1024];
    
    createMedicalCommand(messageBuffer, sizeof(messageBuffer), deviceId);
    
    IOTHUB_MESSAGE_HANDLE messageHandle = IoTHubMessage_CreateFromString(messageBuffer);
    if (messageHandle == NULL)
    {
        printf("[ERROR] Failed to create message\n");
        return 1;
    }
    
    printf("\n========================================\n");
    printf("Sending C2D message to: %s\n", deviceId);
    printf("========================================\n");
    printf("Message content:\n%s\n", messageBuffer);
    printf("========================================\n\n");
    
    IOTHUB_MESSAGING_RESULT result = IoTHubMessaging_SendAsync(
        messagingHandle,
        deviceId,
        messageHandle,
        messageSendCallback,
        NULL
    );
    
    IoTHubMessage_Destroy(messageHandle);
    
    if (result != IOTHUB_MESSAGING_OK)
    {
        printf("[ERROR] Failed to send message: %d\n", result);
        return 1;
    }
    
    // 送信完了を待機
    int timeout = 10;
    while (timeout > 0 && g_messageCount == 0)
    {
        ThreadAPI_Sleep(100);
        timeout--;
    }
    
    g_messageCount = 0;
    return 0;
}

// 使用方法の表示
void printUsage(const char* programName)
{
    printf("Usage:\n");
    printf("  %s --device <device_id>\n", programName);
    printf("  %s --send_all\n", programName);
    printf("\n");
    printf("Examples:\n");
    printf("  %s --device icu-device01\n", programName);
    printf("  %s --send_all\n", programName);
    printf("\n");
    printf("Environment variable required:\n");
    printf("  IOTHUB_CONNECTION_STRING - IoT Hub connection string\n");
}

int main(int argc, char* argv[])
{
    srand(time(NULL));
    
    // 引数チェック
    if (argc < 2)
    {
        printUsage(argv[0]);
        return 1;
    }
    
    // 環境変数から接続文字列取得
    const char* connectionString = getenv("IOTHUB_CONNECTION_STRING");
    if (connectionString == NULL)
    {
        printf("[ERROR] Environment variable not set: IOTHUB_CONNECTION_STRING\n");
        printf("Please set it using:\n");
        printf("export IOTHUB_CONNECTION_STRING=\"HostName=...\"\n");
        return 1;
    }
    
    printf("=========================================\n");
    printf(" Azure IoT Hub Management App (C)\n");
    printf("=========================================\n\n");
    
    // Service Client の初期化
    IOTHUB_SERVICE_CLIENT_AUTH_HANDLE authHandle = IoTHubServiceClientAuth_CreateFromConnectionString(connectionString);
    if (authHandle == NULL)
    {
        printf("[ERROR] Failed to create service client auth\n");
        return 1;
    }
    
    IOTHUB_MESSAGING_CLIENT_HANDLE messagingHandle = IoTHubMessaging_Create(authHandle);
    if (messagingHandle == NULL)
    {
        printf("[ERROR] Failed to create messaging handle\n");
        IoTHubServiceClientAuth_Destroy(authHandle);
        return 1;
    }
    
    // Messaging を開く
    IOTHUB_MESSAGING_RESULT result = IoTHubMessaging_Open(messagingHandle, NULL, NULL);
    if (result != IOTHUB_MESSAGING_OK)
    {
        printf("[ERROR] Failed to open messaging: %d\n", result);
        IoTHubMessaging_Destroy(messagingHandle);
        IoTHubServiceClientAuth_Destroy(authHandle);
        return 1;
    }
    
    printf("[INFO] Connected to IoT Hub\n\n");
    
    // コマンドライン引数の処理
    if (strcmp(argv[1], "--device") == 0 && argc >= 3)
    {
        const char* deviceId = argv[2];
        sendMessageToDevice(messagingHandle, deviceId);
    }
    else if (strcmp(argv[1], "--send_all") == 0 || strcmp(argv[1], "--all") == 0)
    {
        // 全デバイスに送信
        const char* devices[] = {
            "icu-device01",
            "icu-device02",
            "general-device01",
            "general-device02",
            "general-device03"
        };
        
        int deviceCount = sizeof(devices) / sizeof(devices[0]);
        
        printf("Sending messages to %d devices...\n\n", deviceCount);
        
        for (int i = 0; i < deviceCount; i++)
        {
            sendMessageToDevice(messagingHandle, devices[i]);
            ThreadAPI_Sleep(500); // デバイス間で少し待機
        }
        
        printf("\nCompleted sending to all devices\n");
    }
    else
    {
        printf("[ERROR] Invalid arguments\n\n");
        printUsage(argv[0]);
        IoTHubMessaging_Close(messagingHandle);
        IoTHubMessaging_Destroy(messagingHandle);
        IoTHubServiceClientAuth_Destroy(authHandle);
        return 1;
    }
    
    // クリーンアップ
    IoTHubMessaging_Close(messagingHandle);
    IoTHubMessaging_Destroy(messagingHandle);
    IoTHubServiceClientAuth_Destroy(authHandle);
    
    printf("\n[INFO] Application completed\n");
    return 0;
}
