#!/usr/bin/env bash
#
# 5台のデバイスシミュレータを並行起動するスクリプト
# Power BI 分析向け: 3時間分のリアルなデータを生成
#
# 使い方:
#   source ../.env
#   source .venv/bin/activate
#   bash run_all_devices.sh
#
# 停止:
#   Ctrl+C または: kill $(jobs -p)
#

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==========================================="
echo " 5台デバイス並行シミュレーション"
echo "==========================================="
echo ""
echo "シナリオ:"
echo "  ICU-01    : 重症患者     (10秒間隔, warning 20%, critical 5%)"
echo "  ICU-02    : 安定回復中   (10秒間隔, warning  5%, critical 0.3%)"
echo "  General-01: 一般入院     (30秒間隔, warning  8%, critical 0.5%)"
echo "  General-02: 経過観察     (30秒間隔, warning  3%, critical 0.1%)"
echo "  General-03: 容態悪化傾向 (30秒間隔, warning 15%, critical 3%)"
echo ""
echo "想定実行時間: 3時間 (Ctrl+C で早期終了可)"
echo "総メッセージ数 (3時間): 約 2,520件"
echo "  ICU (10秒間隔 x 2台):     2 x 1,080 = 2,160件"
echo "  General (30秒間隔 x 3台): 3 x   360 = 1,080件"
echo "  合計: 約 3,240件"
echo ""
echo "==========================================="

# 環境変数チェック
MISSING=0
for VAR in ICU_DEVICE01_CONNECTION_STRING ICU_DEVICE02_CONNECTION_STRING \
           GENERAL_DEVICE01_CONNECTION_STRING GENERAL_DEVICE02_CONNECTION_STRING \
           GENERAL_DEVICE03_CONNECTION_STRING; do
    if [ -z "${!VAR}" ]; then
        echo "[ERROR] $VAR が設定されていません"
        MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "先に環境変数を読み込んでください: source ../.env"
    exit 1
fi

echo "3秒後に開始します..."
sleep 3

# --- ICU デバイス (10秒間隔: 高頻度モニタリング) ---

# ICU-01: 重症患者 - 異常が比較的多い
echo "[START] icu-device01 (重症患者)"
python device_simulator.py icu-device01 telemetry \
    --interval 10000 \
    --warning-rate 20 \
    --critical-rate 5 &

sleep 2  # 起動タイミングをずらしてログを見やすくする

# ICU-02: 安定回復中 - ほぼ正常だが時々 warning
echo "[START] icu-device02 (安定回復中)"
python device_simulator.py icu-device02 telemetry \
    --interval 10000 \
    --warning-rate 5 \
    --critical-rate 0.3 &

sleep 2

# --- 一般病棟デバイス (30秒間隔: 通常モニタリング) ---

# General-01: 一般入院 - 標準的なパターン
echo "[START] general-device01 (一般入院)"
python device_simulator.py general-device01 telemetry \
    --interval 30000 \
    --warning-rate 8 \
    --critical-rate 0.5 &

sleep 2

# General-02: 経過観察 - 非常に安定
echo "[START] general-device02 (経過観察)"
python device_simulator.py general-device02 telemetry \
    --interval 30000 \
    --warning-rate 3 \
    --critical-rate 0.1 &

sleep 2

# General-03: 容態悪化傾向 - 異常値が多め（要注意患者）
echo "[START] general-device03 (容態悪化傾向)"
python device_simulator.py general-device03 telemetry \
    --interval 30000 \
    --warning-rate 15 \
    --critical-rate 3 &

echo ""
echo "==========================================="
echo " 全デバイス起動完了 (5台)"
echo " 停止するには Ctrl+C を押してください"
echo "==========================================="

# 全バックグラウンドプロセスを待機
# Ctrl+C で全プロセスを停止
trap 'echo ""; echo "[INFO] 全デバイスを停止しています..."; kill $(jobs -p) 2>/dev/null; wait; echo "[INFO] 完了"; exit 0' INT TERM

wait
