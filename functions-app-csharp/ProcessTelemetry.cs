// ---------------------------------------------------------------------------
// Azure Functions - IoT テレメトリ処理バックエンド (C# isolated worker)
//
// IoT Hub (Event Hub 互換エンドポイント) からテレメトリを受信し:
//   1. クラウド側でステータスを再判定
//   2. 加工済み JSON を /processed コンテナに出力
//   3. critical 時に Logic Apps へ HTTP POST (メール通知)
// ---------------------------------------------------------------------------

using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace FunctionsApp;

/// <summary>
/// テレメトリの JSON モデル (デバイスシミュレータから送信されるデータ)
/// </summary>
public class TelemetryData
{
    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = "unknown";

    [JsonPropertyName("timestamp")]
    public string Timestamp { get; set; } = "";

    [JsonPropertyName("heartRate")]
    public double? HeartRate { get; set; }

    [JsonPropertyName("bloodPressureSystolic")]
    public double? BloodPressureSystolic { get; set; }

    [JsonPropertyName("bloodPressureDiastolic")]
    public double? BloodPressureDiastolic { get; set; }

    [JsonPropertyName("bodyTemperature")]
    public double? BodyTemperature { get; set; }

    [JsonPropertyName("spo2")]
    public double? Spo2 { get; set; }

    [JsonPropertyName("respiratoryRate")]
    public double? RespiratoryRate { get; set; }

    [JsonPropertyName("patientStatus")]
    public string PatientStatus { get; set; } = "";
}

/// <summary>
/// 加工済みレコード (/processed コンテナに出力する JSON)
/// </summary>
public class ProcessedRecord
{
    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("timestamp")]
    public string Timestamp { get; set; } = "";

    [JsonPropertyName("heartRate")]
    public double? HeartRate { get; set; }

    [JsonPropertyName("bloodPressureSystolic")]
    public double? BloodPressureSystolic { get; set; }

    [JsonPropertyName("bloodPressureDiastolic")]
    public double? BloodPressureDiastolic { get; set; }

    [JsonPropertyName("bodyTemperature")]
    public double? BodyTemperature { get; set; }

    [JsonPropertyName("spo2")]
    public double? Spo2 { get; set; }

    [JsonPropertyName("respiratoryRate")]
    public double? RespiratoryRate { get; set; }

    [JsonPropertyName("patientStatus")]
    public string PatientStatus { get; set; } = "";

    [JsonPropertyName("processedAt")]
    public string ProcessedAt { get; set; } = "";

    [JsonPropertyName("serverStatus")]
    public string ServerStatus { get; set; } = "";

    [JsonPropertyName("alerts")]
    public List<string> Alerts { get; set; } = [];
}

/// <summary>
/// Logic Apps に送信するアラートペイロード
/// </summary>
public class AlertPayload
{
    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("timestamp")]
    public string Timestamp { get; set; } = "";

    [JsonPropertyName("serverStatus")]
    public string ServerStatus { get; set; } = "";

    [JsonPropertyName("alerts")]
    public List<string> Alerts { get; set; } = [];

    [JsonPropertyName("heartRate")]
    public double? HeartRate { get; set; }

    [JsonPropertyName("bodyTemperature")]
    public double? BodyTemperature { get; set; }

    [JsonPropertyName("spo2")]
    public double? Spo2 { get; set; }

    [JsonPropertyName("message")]
    public string Message { get; set; } = "";
}

/// <summary>
/// EventHub Trigger 関数 - IoT Hub テレメトリ処理
/// </summary>
public class ProcessTelemetry
{
    private readonly ILogger<ProcessTelemetry> _logger;
    private readonly IHttpClientFactory _httpClientFactory;

    // ステータス判定の閾値 (デバイスシミュレータと統一)
    private const double HeartRateWarning = 100;
    private const double HeartRateCritical = 120;
    private const double BodyTempWarning = 37.5;
    private const double BodyTempCritical = 38.5;
    private const double Spo2Warning = 95;
    private const double Spo2Critical = 90;

    private static readonly JsonSerializerOptions s_jsonOptions = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public ProcessTelemetry(ILogger<ProcessTelemetry> logger, IHttpClientFactory httpClientFactory)
    {
        _logger = logger;
        _httpClientFactory = httpClientFactory;
    }

    /// <summary>
    /// IoT Hub (Event Hub) からテレメトリをバッチ受信し処理する。
    /// </summary>
    [Function(nameof(ProcessTelemetry))]
    public async Task Run(
        [EventHubTrigger(
            eventHubName: "%IoTHubEventHubName%",
            Connection = "IoTHubEventHubConnectionString",
            ConsumerGroup = "%IoTHubConsumerGroup%",
            IsBatched = true)]
        string[] messages)
    {
        int processedCount = 0;
        int criticalCount = 0;
        int errorCount = 0;

        foreach (var message in messages)
        {
            try
            {
                // --- 1. JSON パース ---
                var telemetry = JsonSerializer.Deserialize<TelemetryData>(message);
                if (telemetry is null)
                {
                    errorCount++;
                    _logger.LogError("[PARSE-ERROR] デシリアライズ結果が null: {Body}", message[..Math.Min(200, message.Length)]);
                    continue;
                }

                // --- 2. ステータス再判定 ---
                var (serverStatus, alerts) = EvaluateStatus(telemetry);

                // --- 3. 加工済みレコード構築 & Blob 出力 ---
                var record = BuildProcessedRecord(telemetry, serverStatus, alerts);
                await UploadToBlobAsync(record);
                processedCount++;

                // --- 4. critical 時は Logic Apps に通知 ---
                if (serverStatus == "critical")
                {
                    criticalCount++;
                    var alertPayload = BuildAlertPayload(record);
                    _logger.LogWarning("[CRITICAL] {DeviceId} | {Message}", alertPayload.DeviceId, alertPayload.Message);
                    await NotifyLogicAppAsync(alertPayload);
                }
            }
            catch (JsonException ex)
            {
                errorCount++;
                _logger.LogError("[PARSE-ERROR] JSON パース失敗: {Error} | body: {Body}", ex.Message, message[..Math.Min(200, message.Length)]);
            }
            catch (Exception ex)
            {
                errorCount++;
                _logger.LogError("[PROCESS-ERROR] 処理エラー: {Error}", ex.Message);
            }
        }

        _logger.LogInformation("[BATCH] 処理完了: {Processed}件 (critical: {Critical}, エラー: {Errors})", processedCount, criticalCount, errorCount);
    }

    // -----------------------------------------------------------------------
    // ヘルパーメソッド
    // -----------------------------------------------------------------------

    /// <summary>
    /// テレメトリ値からクラウド側ステータスを再判定する。
    /// </summary>
    private static (string status, List<string> alerts) EvaluateStatus(TelemetryData telemetry)
    {
        var alerts = new List<string>();
        var status = "normal";

        // heartRate (上限チェック)
        if (telemetry.HeartRate.HasValue)
        {
            if (telemetry.HeartRate.Value > HeartRateCritical)
            {
                alerts.Add("heartRate:high");
                status = "critical";
            }
            else if (telemetry.HeartRate.Value > HeartRateWarning)
            {
                alerts.Add("heartRate:elevated");
                if (status != "critical") status = "warning";
            }
        }

        // bodyTemperature (上限チェック)
        if (telemetry.BodyTemperature.HasValue)
        {
            if (telemetry.BodyTemperature.Value > BodyTempCritical)
            {
                alerts.Add("bodyTemperature:high");
                status = "critical";
            }
            else if (telemetry.BodyTemperature.Value > BodyTempWarning)
            {
                alerts.Add("bodyTemperature:elevated");
                if (status != "critical") status = "warning";
            }
        }

        // spo2 (下限チェック)
        if (telemetry.Spo2.HasValue)
        {
            if (telemetry.Spo2.Value < Spo2Critical)
            {
                alerts.Add("spo2:low");
                status = "critical";
            }
            else if (telemetry.Spo2.Value < Spo2Warning)
            {
                alerts.Add("spo2:elevated");
                if (status != "critical") status = "warning";
            }
        }

        return (status, alerts);
    }

    /// <summary>加工済みレコードを構築する。</summary>
    private static ProcessedRecord BuildProcessedRecord(TelemetryData telemetry, string serverStatus, List<string> alerts)
    {
        return new ProcessedRecord
        {
            DeviceId = telemetry.DeviceId,
            Timestamp = telemetry.Timestamp,
            HeartRate = telemetry.HeartRate,
            BloodPressureSystolic = telemetry.BloodPressureSystolic,
            BloodPressureDiastolic = telemetry.BloodPressureDiastolic,
            BodyTemperature = telemetry.BodyTemperature,
            Spo2 = telemetry.Spo2,
            RespiratoryRate = telemetry.RespiratoryRate,
            PatientStatus = telemetry.PatientStatus,
            ProcessedAt = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ServerStatus = serverStatus,
            Alerts = alerts,
        };
    }

    /// <summary>Logic Apps に送信するアラートペイロードを構築する。</summary>
    private static AlertPayload BuildAlertPayload(ProcessedRecord record)
    {
        var details = new List<string>();
        if (record.HeartRate.HasValue) details.Add($"heartRate={record.HeartRate}");
        if (record.BodyTemperature.HasValue) details.Add($"bodyTemperature={record.BodyTemperature}");
        if (record.Spo2.HasValue) details.Add($"spo2={record.Spo2}");

        var alertsStr = string.Join(", ", record.Alerts);

        return new AlertPayload
        {
            DeviceId = record.DeviceId,
            Timestamp = record.Timestamp,
            ServerStatus = record.ServerStatus,
            Alerts = record.Alerts,
            HeartRate = record.HeartRate,
            BodyTemperature = record.BodyTemperature,
            Spo2 = record.Spo2,
            Message = $"[CRITICAL] {record.DeviceId}: {string.Join(", ", details)} ({alertsStr})",
        };
    }

    /// <summary>
    /// 加工済み JSON を /processed コンテナにアップロードする。
    /// 接続文字列 (アクセスキー) を使用。
    /// </summary>
    private async Task UploadToBlobAsync(ProcessedRecord record)
    {
        var connStr = Environment.GetEnvironmentVariable("ProcessedBlobConnectionString") ?? "";
        var container = Environment.GetEnvironmentVariable("ProcessedBlobContainerName") ?? "processed";

        if (string.IsNullOrEmpty(connStr))
        {
            _logger.LogError("[BLOB-FAIL] ProcessedBlobConnectionString が未設定です");
            return;
        }

        // パス: {deviceId}/{YYYY-MM-DD}/{HH-mm-ss-ffffff}.json
        if (!DateTime.TryParseExact(record.ProcessedAt, "yyyy-MM-ddTHH:mm:ssZ",
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AssumeUniversal, out var dt))
        {
            dt = DateTime.UtcNow;
        }

        var blobName = $"{record.DeviceId}/{dt:yyyy-MM-dd}/{dt:HH-mm-ss}-{dt:ffffff}.json";

        try
        {
            var blobServiceClient = new BlobServiceClient(connStr);
            var containerClient = blobServiceClient.GetBlobContainerClient(container);
            var blobClient = containerClient.GetBlobClient(blobName);

            var json = JsonSerializer.Serialize(record, s_jsonOptions);
            using var stream = new MemoryStream(Encoding.UTF8.GetBytes(json));
            await blobClient.UploadAsync(stream, overwrite: true);

            _logger.LogDebug("[BLOB-OK] {Container}/{BlobName}", container, blobName);
        }
        catch (Exception ex)
        {
            _logger.LogError("[BLOB-FAIL] {BlobName}: {Error}", blobName, ex.Message);
        }
    }

    /// <summary>
    /// Logic Apps の HTTP Webhook にアラートを POST する。未設定時はスキップ。
    /// </summary>
    private async Task NotifyLogicAppAsync(AlertPayload payload)
    {
        var logicAppUrl = Environment.GetEnvironmentVariable("LOGIC_APP_URL") ?? "";

        if (string.IsNullOrEmpty(logicAppUrl))
        {
            _logger.LogWarning("[ALERT-SKIP] LOGIC_APP_URL が未設定のため通知をスキップ: {Message}", payload.Message);
            return;
        }

        try
        {
            var client = _httpClientFactory.CreateClient();
            var json = JsonSerializer.Serialize(payload, s_jsonOptions);
            using var content = new StringContent(json, Encoding.UTF8, "application/json");
            var response = await client.PostAsync(logicAppUrl, content);
            response.EnsureSuccessStatusCode();
            _logger.LogInformation("[ALERT-SENT] {DeviceId} → Logic Apps (HTTP {StatusCode})", payload.DeviceId, (int)response.StatusCode);
        }
        catch (Exception ex)
        {
            // Logic Apps 失敗でもテレメトリ処理は止めない
            _logger.LogError("[ALERT-FAIL] Logic Apps への通知に失敗: {Error}", ex.Message);
        }
    }
}
