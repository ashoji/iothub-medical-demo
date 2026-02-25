#!/usr/bin/env python3
"""
Azure IoT Hub 管理アプリケーション

医療機器デバイスに Cloud-to-Device メッセージを送信するツール
"""

import os
import sys
import argparse
import json
from datetime import datetime
from azure.iot.hub import IoTHubRegistryManager
from azure.iot.hub.models import CloudToDeviceMethod, Twin


def get_connection_string():
    """環境変数から IoT Hub 接続文字列を取得"""
    conn_str = os.environ.get('IOTHUB_CONNECTION_STRING')
    if not conn_str:
        print("Error: IOTHUB_CONNECTION_STRING environment variable not set")
        print("Please set it using:")
        print('export IOTHUB_CONNECTION_STRING="HostName=..."')
        sys.exit(1)
    return conn_str


def list_devices(registry_manager):
    """登録されているデバイスの一覧を取得"""
    try:
        devices = registry_manager.get_devices(max_number_of_devices=100)
        return devices
    except Exception as e:
        print(f"Error listing devices: {e}")
        return []


def create_medical_command():
    """医療機器向けのコマンドメッセージを生成"""
    selected_command = {
        "command": "request_diagnostic_data",
        "description": "診断データの要求",
        "parameters": {
            "include_logs": True,
            "time_range_hours": 24
        }
    }
    
    message = {
        "messageId": f"msg-{datetime.utcnow().strftime('%Y%m%d%H%M%S')}",
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "command": selected_command["command"],
        "description": selected_command["description"],
        "parameters": selected_command["parameters"],
        "sender": "management-app",
        "priority": "normal"
    }
    
    return message


def send_c2d_message(registry_manager, device_id):
    """Cloud-to-Device メッセージを送信"""
    try:
        # メッセージの作成
        message = create_medical_command()
        message_json = json.dumps(message, indent=2)
        
        print(f"\n--- Sending message to {device_id} ---")
        print(f"Command: {message['command']}")
        print(f"Description: {message['description']}")
        print(f"Message content:\n{message_json}")
        
        # メッセージ送信
        registry_manager.send_c2d_message(device_id, message_json)
        
        print(f"Message sent successfully to {device_id}")
        return True
        
    except Exception as e:
        print(f"Error sending message to {device_id}: {e}")
        return False


def main():
    """メイン処理"""
    parser = argparse.ArgumentParser(
        description='Azure IoT Hub 管理アプリケーション - Cloud-to-Device メッセージ送信'
    )
    parser.add_argument(
        '--device',
        type=str,
        help='送信先デバイスID (例: device01)'
    )
    parser.add_argument(
        '--send_all',
        action='store_true',
        help='全てのデバイスにメッセージを送信'
    )
    parser.add_argument(
        '--list',
        action='store_true',
        help='登録されているデバイスの一覧を表示'
    )
    
    args = parser.parse_args()
    
    # 接続文字列の取得
    connection_string = get_connection_string()
    
    # IoT Hub Registry Manager の初期化
    try:
        registry_manager = IoTHubRegistryManager(connection_string)
        print("Connected to IoT Hub successfully")
    except Exception as e:
        print(f"Error connecting to IoT Hub: {e}")
        sys.exit(1)
    
    # デバイス一覧の表示
    if args.list:
        print("\n--- Registered Devices ---")
        devices = list_devices(registry_manager)
        if devices:
            for device in devices:
                print(f"  - {device.device_id}")
        else:
            print("  No devices found")
        return
    
    # 全デバイスに送信
    if args.send_all:
        devices = list_devices(registry_manager)
        if not devices:
            print("No devices found to send messages to")
            return
        
        device_ids = [device.device_id for device in devices]
        print(f"\nSending messages to {len(device_ids)} device(s)...")
        success_count = 0
        for device_id in device_ids:
            if send_c2d_message(registry_manager, device_id):
                success_count += 1
        
        print(f"\n--- Summary ---")
        print(f"Total devices: {len(device_ids)}")
        print(f"Success: {success_count}")
        print(f"Failed: {len(device_ids) - success_count}")
        return
    
    # 特定デバイスに送信
    if args.device:
        send_c2d_message(registry_manager, args.device)
        return
    
    # 引数が指定されていない場合
    parser.print_help()
    print("\n使用例:")
    print("  # デバイス一覧の表示")
    print("  python device_manager.py --list")
    print("\n  # 特定デバイスにメッセージ送信")
    print("  python device_manager.py --device device01")
    print("\n  # 全デバイスにメッセージ送信")
    print("  python device_manager.py --send_all")


if __name__ == "__main__":
    main()
