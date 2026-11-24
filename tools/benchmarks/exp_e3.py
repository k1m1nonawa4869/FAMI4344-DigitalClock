# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/benchmarks/exp_e3.py — Phân tích thực nghiệm Polling vs Ngắt vs Chốt phần cứng 0-ns (Experiment E3)
# CHUYÊN ĐỀ KTMT: Chương 05: Hệ thống Vào/Ra & Cơ chế ngắt vi xử lý (Interrupt & Hardware Timestamping)
# VAI TRÒ:        Đo đạc độ trễ (Latency) và độ bất định (Jitter) khi ghi nhận thời điểm bấm nút bằng 4 kỹ thuật.
# MÔ TẢ:          - Chạy song song 4 cơ chế: Polling vòng lặp, ISR ngắt thông thường, ISR tối ưu và Chốt 0-ns.
#                 - Đo độ trễ từ thời điểm nút nhấn vật lý đổi trạng thái đến khi thời gian được ghi nhận.
#                 - Xuất bảng phân phối xác suất và biểu đồ so sánh độ chính xác phục vụ báo cáo kỹ thuật.
# ============================================================================

"""Thí nghiệm E3 (báo cáo, chủ TV3 + TV2): polling vs ngắt vs capture phần cứng khi lấy thời điểm bấm nút.

    python tools/benchmarks/exp_e3.py [--n 1000]      # bảng Markdown ra stdout; CSV từng lần bấm ở work/exp_e3/

Dịch fw/exp/e3_poll.s và e3_irq.s với D = 2 / 100 / 1526 (thay dòng `.eqv D_VAL`), chạy tb/exp_e3_tb.v song song.
Độ trễ đo bằng chu kỳ 50 MHz (không phụ thuộc G_N) → µs ở board = chu kỳ / 50.
Sai số ms ở board (1 ms = 50 000 chu kỳ, lúc bấm ngẫu nhiên trong ms): kỳ vọng số ms đọc dư = trễ / 50 000.
"""
import argparse
import csv
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = os.path.dirname(HERE)
ROOT = os.path.dirname(TOOLS_DIR)
OUT = os.path.join(ROOT, "work", "exp_e3")
DS = (2, 100, 1526)
MODES = ("poll", "irq")


def run(args):
    mode, d, n = args
    src = os.path.join(OUT, "e3_%s_%d.s" % (mode, d))
    text = open(os.path.join(ROOT, "fw", "exp", "e3_%s.s" % mode), encoding="utf-8").read()
    text, k = re.subn(r"(\.eqv\s+D_VAL\s+)\d+", r"\g<1>%d" % d, text)
    assert k == 1
    open(src, "w", encoding="utf-8").write(text)
    hexf = src[:-2] + ".hex"
    subprocess.run([sys.executable, os.path.join(TOOLS_DIR, "fw_build.py"), src, hexf], check=True, capture_output=True)
    out = subprocess.run(["vvp", "-n", os.path.join(ROOT, "work", "exp_e3_tb.vvp"), "+imem=" + hexf, "+d=%d" % d,
                          "+n=%d" % n, "+csv=" + src[:-2] + ".csv"], cwd=ROOT, capture_output=True, text=True).stdout
    if "PASS exp_e3_tb" not in out:
        sys.exit("FAIL %s D=%d:\n%s" % (mode, d, out))
    lat = [int(r["lat_cyc"]) for r in csv.DictReader(open(src[:-2] + ".csv"))]
    return mode, d, lat


def main():
    sys.stdout.reconfigure(encoding="utf-8")       # console Windows cp1252 không in được tiếng Việt
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=1000)
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    jobs = [(m, d, a.n) for d in DS for m in MODES]
    with ThreadPoolExecutor(max_workers=len(jobs)) as ex:
        res = list(ex.map(run, jobs))
    print("| D | Tốc độ G1 (board) | Cách | n | Trễ min / TB / max (µs ở board) | Sai số TB (ms, board, ước tính) |")
    print("|---|---|---|---|---|---|")
    for mode, d, lat in res:
        mean = sum(lat) / len(lat)
        print("| %d | %.1f k lệnh/s | %s | %d | %.2f / %.2f / %.2f | %.3f |" % (
            d, 50000 / d, {"poll": "polling", "irq": "ngắt"}[mode], len(lat), min(lat) / 50, mean / 50, max(lat) / 50,
            mean / 50000))
    print("| mọi D | | capture lap / dấu BTN_EVENT | %d mỗi ca | 0 (chụp đúng chu kỳ nhấn) | 0 |" % a.n)


if __name__ == "__main__":
    main()
