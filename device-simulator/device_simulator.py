#!/usr/bin/env python3
"""
Azure IoT Hub デバイスシミュレータ (Python版)

医療機器を想定したテレメトリ送信と画像アップロード機能
C言語版 (device_simulator.c) と同一のデータ形式で送信します。

使用方法:
  # テレメトリ送信モード（デフォルト: 5秒間隔）
  python device_simulator.py icu-device01 telemetry

  # カスタム間隔（1秒）、異常レート指定
  python device_simulator.py icu-device01 telemetry --interval 1000 --warning-rate 10 --critical-rate 1

  # 画像アップロードモード
  python device_simulator.py icu-device01 upload --file /path/to/image.jpg

環境変数:
  <DEVICE_NAME>_CONNECTION_STRING  デバイスの接続文字列
  例: export ICU_DEVICE01_CONNECTION_STRING="HostName=..."
"""

import os
import sys
import json
import time
import random
import signal
import argparse
from datetime import datetime, timezone

from azure.iot.device import IoTHubDeviceClient, Message
from azure.iot.device.exceptions import OperationCancelled


# ANSI カラーコード
COLOR_RED = "\033[0;31m"
COLOR_GREEN = "\033[0;32m"
COLOR_YELLOW = "\033[0;33m"
COLOR_RESET = "\033[0m"

# グローバルフラグ
g_continue_running = True


def signal_handler(sig, frame):
    """シグナルハンドラ（Ctrl+C での終了）"""
    global g_continue_running
    print("\n[INFO] Interrupt signal received. Shutting down...")
    g_continue_running = False


def generate_medical_telemetry(device_id: str, warning_rate: float = 10.0, critical_rate: float = 1.0) -> dict:
    """
    医療機器テレメトリデータの生成
    normal / warning / critical がランダムに混在するデータを生成

    Args:
        device_id: デバイスID
        warning_rate: warning の発生確率 (%, デフォルト: 10.0)
        critical_rate: critical の発生確率 (%, デフォルト: 1.0)
    """
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # ステータスをランダムに決定
    cr = critical_rate / 100.0
    wr = warning_rate / 100.0
    roll = random.random()
    if roll < cr:
        target_status = "critical"
    elif roll < cr + wr:
        target_status = "warning"
    else:
        target_status = "normal"

    if target_status == "critical":
        # 異常値（重篤）: 少なくとも1つが critical 閾値を超える
        heart_rate = random.choice([
            random.randint(121, 160),                           # 頻脈
            random.randint(60, 99),                             # 正常
        ])
        body_temperature = random.choice([
            round(random.uniform(38.6, 40.0), 1),              # 高熱
            round(random.uniform(36.0, 37.4), 1),              # 正常
        ])
        spo2 = random.choice([
            random.randint(80, 89),                            # 低酸素
            random.randint(95, 100),                           # 正常
        ])
        # critical 条件を少なくとも1つ満たすよう保証
        if heart_rate <= 120 and body_temperature <= 38.5 and spo2 >= 90:
            pick = random.randint(0, 2)
            if pick == 0:
                heart_rate = random.randint(121, 160)
            elif pick == 1:
                body_temperature = round(random.uniform(38.6, 40.0), 1)
            else:
                spo2 = random.randint(80, 89)
    elif target_status == "warning":
        # 異常値（警告）: warning 閾値を超えるが critical には達しない
        heart_rate = random.choice([
            random.randint(101, 120),                           # やや頻脈
            random.randint(60, 99),                             # 正常
        ])
        body_temperature = random.choice([
            round(random.uniform(37.6, 38.5), 1),              # 微熱
            round(random.uniform(36.0, 37.4), 1),              # 正常
        ])
        spo2 = random.choice([
            random.randint(91, 94),                            # やや低酸素
            random.randint(95, 100),                           # 正常
        ])
        # warning 条件を少なくとも1つ満たすよう保証
        if heart_rate <= 100 and body_temperature <= 37.5 and spo2 >= 95:
            pick = random.randint(0, 2)
            if pick == 0:
                heart_rate = random.randint(101, 120)
            elif pick == 1:
                body_temperature = round(random.uniform(37.6, 38.5), 1)
            else:
                spo2 = random.randint(91, 94)
    else:
        # 正常値
        heart_rate = 60 + random.randint(0, 39)                 # 脈拍: 60-99 bpm
        body_temperature = round(36.0 + random.randint(0, 14) / 10.0, 1)  # 体温: 36.0-37.4 °C
        spo2 = 95 + random.randint(0, 5)                       # 酸素飽和度: 95-100%

    # 血圧・呼吸数はステータスに連動して少し揺らす
    if target_status == "critical":
        bp_systolic = 140 + random.randint(0, 40)               # 高血圧: 140-180 mmHg
        bp_diastolic = 90 + random.randint(0, 20)               # 拡張期: 90-110 mmHg
        respiratory_rate = round(22.0 + random.randint(0, 80) / 10.0, 1)  # 頻呼吸: 22.0-30.0
    elif target_status == "warning":
        bp_systolic = 130 + random.randint(0, 20)               # やや高血圧: 130-150 mmHg
        bp_diastolic = 80 + random.randint(0, 15)               # 拡張期: 80-95 mmHg
        respiratory_rate = round(18.0 + random.randint(0, 60) / 10.0, 1)  # やや頻呼吸: 18.0-24.0
    else:
        bp_systolic = 110 + random.randint(0, 29)               # 収縮期血圧: 110-139 mmHg
        bp_diastolic = 70 + random.randint(0, 19)               # 拡張期血圧: 70-89 mmHg
        respiratory_rate = round(12.0 + random.randint(0, 59) / 10.0, 1)  # 呼吸数: 12.0-17.9

    # ステータス判定（実際の値から再計算）
    status = "normal"
    if heart_rate > 100 or body_temperature > 37.5 or spo2 < 95:
        status = "warning"
    if heart_rate > 120 or body_temperature > 38.5 or spo2 < 90:
        status = "critical"

    return {
        "deviceId": device_id,
        "timestamp": timestamp,
        "heartRate": heart_rate,
        "bloodPressureSystolic": bp_systolic,
        "bloodPressureDiastolic": bp_diastolic,
        "bodyTemperature": body_temperature,
        "spo2": spo2,
        "respiratoryRate": respiratory_rate,
        "patientStatus": status,
    }


def c2d_message_handler(message):
    """Cloud-to-Device メッセージ受信コールバック"""
    print(f"\n{COLOR_RED}========================================")
    print("[C2D] Cloud-to-Device message received")
    print(f"========================================{COLOR_RESET}")
    if message.message_id:
        print(f"{COLOR_RED}Message ID: {message.message_id}{COLOR_RESET}")
    if message.correlation_id:
        print(f"{COLOR_RED}Correlation ID: {message.correlation_id}{COLOR_RESET}")
    data = message.data.decode("utf-8") if isinstance(message.data, bytes) else str(message.data)
    print(f"{COLOR_RED}Message content:\n{data}{COLOR_RESET}")
    print(f"{COLOR_RED}========================================{COLOR_RESET}\n")


def run_telemetry_mode(client: IoTHubDeviceClient, device_id: str, interval_ms: int,
                      warning_rate: float = 10.0, critical_rate: float = 1.0):
    """テレメトリ送信モード"""
    message_count = 0

    print("[INFO] Starting telemetry mode")
    print(f"[INFO] Device ID: {device_id}")
    print(f"[INFO] Interval: {interval_ms} ms")
    print(f"[INFO] Warning rate: {warning_rate}%, Critical rate: {critical_rate}%")
    print("[INFO] Press Ctrl+C to stop\n")

    while g_continue_running:
        # テレメトリデータ生成
        telemetry = generate_medical_telemetry(device_id, warning_rate, critical_rate)
        json_str = json.dumps(telemetry)

        # メッセージの作成
        msg = Message(json_str)
        msg.content_type = "application/json"
        msg.content_encoding = "utf-8"

        # メッセージ送信
        message_count += 1
        status = telemetry["patientStatus"]
        if status == "critical":
            color = COLOR_RED
            label = "[CRITICAL]"
        elif status == "warning":
            color = COLOR_YELLOW
            label = "[WARNING] "
        else:
            color = COLOR_GREEN
            label = "[NORMAL]  "
        print(f"[{message_count}] Sending telemetry... {color}{label}{COLOR_RESET}")
        print(f"{color}    Data: {json_str}{COLOR_RESET}")

        try:
            client.send_message(msg)
            print("[OK] Message sent successfully")
        except OperationCancelled:
            print("[INFO] Send cancelled (shutting down)")
            break
        except Exception as e:
            print(f"[ERROR] Failed to send message: {e}")

        # インターバル待機（早期終了対応）
        wait_seconds = interval_ms / 1000.0
        waited = 0.0
        while waited < wait_seconds and g_continue_running:
            time.sleep(min(0.5, wait_seconds - waited))
            waited += 0.5

    print(f"\n[INFO] Telemetry mode stopped. Total messages sent: {message_count}")


def run_upload_mode(client: IoTHubDeviceClient, device_id: str, file_path: str):
    """画像アップロードモード"""
    print("[INFO] Starting upload mode")
    print(f"[INFO] Device ID: {device_id}")
    print(f"[INFO] File path: {file_path}")

    # ファイルの存在確認
    if not os.path.isfile(file_path):
        print(f"[ERROR] File not found: {file_path}")
        return 1

    file_size = os.path.getsize(file_path)
    print(f"[INFO] File size: {file_size} bytes")

    # ファイル名の抽出
    file_name = os.path.basename(file_path)

    # タイムスタンプ付きファイル名の生成 (C版と同じフォーマット)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    dest_file_name = f"{device_id}_{timestamp}_{file_name}"

    print(f"[INFO] Uploading file as: {dest_file_name}")
    print("[INFO] Upload in progress...")

    try:
        # Blob Storage への SAS URI 取得
        storage_info = client.get_storage_info_for_blob(dest_file_name)

        # Blob へアップロード
        from azure.storage.blob import BlobClient

        sas_url = (
            f"https://{storage_info['hostName']}/"
            f"{storage_info['containerName']}/"
            f"{storage_info['blobName']}?"
            f"{storage_info['sasToken']}"
        )

        with open(file_path, "rb") as f:
            blob_client = BlobClient.from_blob_url(sas_url)
            blob_client.upload_blob(f, overwrite=True)

        # アップロード完了通知
        client.notify_blob_upload_status(
            storage_info["correlationId"],
            is_success=True,
            status_code=200,
            status_description="OK",
        )
        print("[OK] File upload completed successfully")
        return 0

    except Exception as e:
        print(f"[ERROR] File upload failed: {e}")
        # エラー通知（可能であれば）
        try:
            client.notify_blob_upload_status(
                storage_info["correlationId"],
                is_success=False,
                status_code=500,
                status_description=str(e),
            )
        except Exception:
            pass
        return 1


def get_connection_string(device_name: str) -> str:
    """環境変数からデバイス接続文字列を取得"""
    # デバイス名を大文字にし、ハイフンをアンダースコアに置換
    env_var_name = device_name.upper().replace("-", "_") + "_CONNECTION_STRING"

    conn_str = os.environ.get(env_var_name)
    if not conn_str:
        print(f"[ERROR] Environment variable not set: {env_var_name}")
        print("Please set it using:")
        print(f'export {env_var_name}="HostName=..."')
        sys.exit(1)
    return conn_str


def main():
    parser = argparse.ArgumentParser(
        description="Azure IoT Hub デバイスシミュレータ (Python版)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用例:
  # テレメトリ送信（5秒間隔、デフォルトレート）
  python device_simulator.py icu-device01 telemetry

  # テレメトリ送信（1秒間隔、レート指定）
  python device_simulator.py icu-device01 telemetry --interval 1000 --warning-rate 15 --critical-rate 5

  # Power BI 向け: クリーンなデータ（異常少なめ）
  python device_simulator.py icu-device01 telemetry --warning-rate 5 --critical-rate 0.5

  # 通知テスト: 異常多めでテスト
  python device_simulator.py icu-device01 telemetry --warning-rate 30 --critical-rate 10

  # ファイルアップロード
  python device_simulator.py icu-device01 upload --file /path/to/image.jpg
""",
    )
    parser.add_argument("device_name", help="デバイス名 (例: icu-device01)")
    subparsers = parser.add_subparsers(dest="mode", help="実行モード")

    # telemetry サブコマンド
    tel_parser = subparsers.add_parser("telemetry", help="テレメトリ送信モード")
    tel_parser.add_argument(
        "--interval",
        type=int,
        default=5000,
        help="送信間隔 (ミリ秒, デフォルト: 5000)",
    )
    tel_parser.add_argument(
        "--warning-rate",
        type=float,
        default=10.0,
        help="warning 発生確率 (%%, デフォルト: 10.0)",
    )
    tel_parser.add_argument(
        "--critical-rate",
        type=float,
        default=1.0,
        help="critical 発生確率 (%%, デフォルト: 1.0)",
    )

    # upload サブコマンド
    upl_parser = subparsers.add_parser("upload", help="ファイルアップロードモード")
    upl_parser.add_argument("--file", required=True, help="アップロードするファイルパス")

    args = parser.parse_args()

    if not args.mode:
        parser.print_help()
        sys.exit(1)

    # シグナルハンドラ設定
    signal.signal(signal.SIGINT, signal_handler)

    # 接続文字列取得
    connection_string = get_connection_string(args.device_name)

    print("===========================================")
    print(" Azure IoT Hub Device Simulator (Python)")
    print("===========================================")
    print(f"Device: {args.device_name}")
    print(f"Mode: {args.mode}")
    print("===========================================\n")

    # IoT Hub デバイスクライアント作成
    try:
        client = IoTHubDeviceClient.create_from_connection_string(connection_string)
        client.on_message_received = c2d_message_handler
        client.connect()
        print("[INFO] Device client created and connected successfully")
    except Exception as e:
        print(f"[ERROR] Failed to create/connect device client: {e}")
        sys.exit(1)

    exit_code = 0
    try:
        if args.mode == "telemetry":
            run_telemetry_mode(client, args.device_name, args.interval,
                              args.warning_rate, args.critical_rate)
        elif args.mode == "upload":
            exit_code = run_upload_mode(client, args.device_name, args.file)
    finally:
        # クリーンアップ
        print("\n[INFO] Cleaning up...")
        try:
            client.disconnect()
            client.shutdown()
        except Exception:
            pass
        print("[INFO] Device simulator terminated")

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
