#!/usr/bin/env python3
# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN MODULE:     results/connector/rtl_bridge.py — Cầu Nối Python ↔ Verilog (vvp)
# CHUYÊN ĐỀ KTMT: Chương 05: Hệ thống Vào/Ra (I/O) & Giao tiếp Phần mềm - Phần cứng
# VAI TRÒ:        Tự động kiểm tra và biên dịch firmware/ + source/ thành mã mô phỏng,
#                 đồng thời cung cấp lớp Chip điều khiển tiến trình vvp thời gian thực.
# MÔ TẢ:          - Quét dấu thời gian của firmware/*.{s,inc} -> dịch work/main.hex qua tools/asm.py.
#                 - Quét dấu thời gian của source/*.v và live_soc_tb.v -> dịch work/live_soc_tb.vvp
#                   qua iverilog -g2005 (nếu có chỉnh sửa RTL/Firmware sẽ tự build lại ngay).
#                 - Giao thức nhị phân gọn: gửi "<mask> <ms>", nhận (t_ms, segs[8], color_idx, beep).
# ============================================================================
"""Cầu nối chung kết nối giao diện đồng hồ trong results/ với backend Verilog RTL thật."""

import os
import shutil
import subprocess
import sys

# ----------------------------------------------------------------------------
# 1. CẤU HÌNH ĐƯỜNG DẪN DỰ ÁN & NHỊP LẤY MẪU KHÔNG ĐỒNG PHA
# ----------------------------------------------------------------------------
CONN_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.dirname(CONN_DIR)
REPO_ROOT = os.path.dirname(RESULTS_DIR)

VVP_PATH = os.path.join(REPO_ROOT, "work", "live_soc_tb.vvp")
HEX_PATH = os.path.join(REPO_ROOT, "work", "main.hex")
LIVE_TB = os.path.join(CONN_DIR, "live_soc_tb.v")

STEP_MS = 47          # 47 ms (~21 FPS); nguyên tố cùng nhau với 10 nên hàng 1/1000 s nhảy đủ 0..9
PRESS_STEPS = 2       # giữ nút 2 bước = 94 ms (> khóa khử rung 10 ms trong source/buttons.v)
GAP_STEPS = 2         # nhả 2 bước = 94 ms giữa hai lần bấm để FIFO sự kiện tách từng lần nhấn
KEYS = {"m": 0, "a": 1, "b": 2, "c": 3}


# ----------------------------------------------------------------------------
# 2. TỰ ĐỘNG BIÊN DỊCH FIRMWARE (firmware/) VÀ PHẦN CỨNG VERILOG (source/)
# ----------------------------------------------------------------------------
def _newest_mtime(paths):
    """Trả về thời điểm chỉnh sửa mới nhất trong danh sách tệp nguồn."""
    return max(os.path.getmtime(p) for p in paths)


def ensure_built():
    """Dịch firmware/main.s -> work/main.hex và source/*.v -> work/live_soc_tb.vvp nếu thiếu/cũ."""
    os.makedirs(os.path.join(REPO_ROOT, "work"), exist_ok=True)
    fw_dir = os.path.join(REPO_ROOT, "firmware")
    fw_files = [
        os.path.join(fw_dir, f)
        for f in os.listdir(fw_dir)
        if f.endswith((".s", ".inc"))
    ]
    if not os.path.exists(HEX_PATH) or os.path.getmtime(HEX_PATH) < _newest_mtime(fw_files):
        print("[build] dịch firmware/main.s -> work/main.hex ...")
        subprocess.check_call(
            [
                sys.executable,
                os.path.join(REPO_ROOT, "tools", "asm.py"),
                "--aw",
                "11",
                "-o",
                HEX_PATH,
                os.path.join(fw_dir, "main.s"),
            ],
            cwd=REPO_ROOT,
        )

    src_dir = os.path.join(REPO_ROOT, "source")
    srcs = sorted(
        os.path.join(src_dir, f) for f in os.listdir(src_dir) if f.endswith(".v")
    )
    if not os.path.exists(VVP_PATH) or os.path.getmtime(VVP_PATH) < _newest_mtime(srcs + [LIVE_TB]):
        if not shutil.which("iverilog"):
            sys.exit("Không tìm thấy iverilog/vvp trong PATH (xem README mục 7.1).")
        print("[build] biên dịch RTL (iverilog -g2005: source/*.v + live_soc_tb.v) ...")
        subprocess.check_call(
            ["iverilog", "-g2005", "-Wno-timescale", "-o", VVP_PATH, LIVE_TB] + srcs,
            cwd=REPO_ROOT,
        )


# ----------------------------------------------------------------------------
# 3. LỚP CHIP: ĐIỀU KHIỂN TIẾN TRÌNH VVP TƯƠNG TÁC QUA STDIN / STDOUT
# ----------------------------------------------------------------------------
class Chip:
    """Tiến trình vvp chạy WatchChip SoC; step(mask, ms) trả về (t_ms, segs[8], color_idx, beep)."""

    def __init__(self):
        # Dùng đường dẫn tương đối + cwd=REPO_ROOT để khớp bộ đệm +imem= trong live_soc_tb.v
        self.p = subprocess.Popen(
            ["vvp", "-n", "work/live_soc_tb.vvp", "+imem=work/main.hex"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
            cwd=REPO_ROOT,
        )
        while True:
            ln = self.p.stdout.readline()
            if not ln:
                sys.exit("vvp thoát sớm — kiểm tra lại biên dịch RTL.")
            if ln.startswith("READY"):
                break

    def step(self, mask, ms=STEP_MS):
        """Gửi mặt nạ 4 nút bấm và khoảng chạy ms; đọc lại khung 8 LED, màu V_COLOR và trạng thái còi."""
        self.p.stdin.write(f"{mask} {ms}\n")
        self.p.stdin.flush()
        while True:
            ln = self.p.stdout.readline()
            if not ln:
                sys.exit("vvp ngừng phản hồi.")
            if ln.startswith("F "):
                f = ln.split()
                t_ms = int(f[1])
                shown = int(f[2], 16)
                lit = int(f[3], 16)
                color_idx = int(f[4], 16) & 0x3
                beep = f[5] == "1"
                # Tách 8 byte {dp, gfedcba} từ S7 (trái) tới S0 (phải)
                segs = [
                    (shown >> (8 * i)) & 0xFF if (lit >> i) & 1 else 0
                    for i in range(7, -1, -1)
                ]
                return t_ms, segs, color_idx, beep

    def close(self):
        """Đóng stdin để live_soc_tb nhận EOF và thoát sạch ($finish)."""
        try:
            self.p.stdin.close()
            self.p.wait(timeout=3)
        except Exception:
            self.p.kill()
