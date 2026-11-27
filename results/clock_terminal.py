#!/usr/bin/env python3
# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    results/clock_terminal.py — Ứng Dụng Đồng Hồ Terminal (Verilog Backend)
# CHUYÊN ĐỀ KTMT: Chương 05: Hệ thống Vào/Ra (I/O) & Giao diện Tương tác Thời gian thực
# VAI TRÒ:        Màn hình hiển thị LED 7 đoạn cỡ lớn & bàn phím điều khiển trên Terminal,
#                 lấy dữ liệu hiển thị và trạng thái màu/còi 100% từ chip Verilog thật.
# MÔ TẢ:          - Tự động biên dịch firmware/ & source/ thông qua results/connector/rtl_bridge.py.
#                 - Giải mã tín hiệu chân an/seg/dp bằng tools/seg7_codec.py (không đụng testbench/).
#                 - Hỗ trợ đổi 4 chủ đề màu ANSI trực tiếp theo thanh ghi V_COLOR của firmware
#                   khi bấm nút C ở chế độ TIME, phím đổi tốc độ 1x/2x/4x và cờ --selftest.
# ============================================================================

"""clock_terminal.py — Ứng dụng ĐỒNG HỒ trên terminal, backend là chip Verilog thật.

Phím:  M = MODE   A / B / C = ba nút còn lại   1 / 2 / 4 = tốc độ   Q = thoát
  MODE chuyển TIME -> ALARM -> STOPWATCH -> TIMER -> SET.  Chi tiết: README mục 4.

Chạy (từ thư mục envs/FAMI4344-DigitalClock):
  python results/clock_terminal.py                # chạy tương tác thời gian thực (1:1)
  python results/clock_terminal.py --speed 4      # nhanh gấp 4 (xem báo thức, hẹn giờ nhanh)
  python results/clock_terminal.py --selftest     # tự bấm phím kiểm RTL đầu-cuối rồi thoát
"""

import argparse
import os
import sys
import time

# ----------------------------------------------------------------------------
# 1. NẠP BỘ GIẢI MÃ LED (tools/seg7_codec.py) VÀ CẦU NỐI RTL (results/connector/)
# ----------------------------------------------------------------------------
RESULTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(RESULTS_DIR)
sys.path.insert(0, os.path.join(REPO_ROOT, "tools"))
sys.path.insert(0, os.path.join(RESULTS_DIR, "connector"))

import rtl_bridge  # noqa: E402
import seg7_codec  # noqa: E402

# 4 chủ đề màu LED khớp thứ tự V_COLOR (0..3) trong firmware/time_mode.s
LED_ANSI = ("\x1b[91m", "\x1b[92m", "\x1b[96m", "\x1b[93m")
LED_NAMES = ("Đỏ", "Xanh lá", "Xanh lam", "Vàng")
TAB = None


# ----------------------------------------------------------------------------
# 2. DỰNG KHUNG TERMINAL ANSI (KHÔNG CHỚP) & ĐỌC PHÍM KHÔNG CHẶN ĐA NỀN TẢNG
# ----------------------------------------------------------------------------
def render(t_ms, segs, color_idx, beep, held, speed, chess=False, mode=0):
    """Vẽ khung đồng hồ LED 7 đoạn bằng ANSI tại chỗ (chỉ dùng \\x1b[H và \\x1b[K)."""
    big = "\n".join(ln + "\x1b[K" for ln in seg7_codec.big(segs, TAB, chess=chess, mode=mode).splitlines())
    line = seg7_codec.text(segs, TAB, chess=chess, mode=mode)
    ansi_col = LED_ANSI[color_idx & 0x3]
    col_name = LED_NAMES[color_idx & 0x3]
    sim_s = t_ms / 1000.0
    chess_hint = ""
    if chess:
        l_unit = "SEC.CC" if ((segs[1] & 0x80) and (segs[3] & 0x80)) else "MIN:SEC"
        r_unit = "SEC.CC" if ((segs[5] & 0x80) and (segs[7] & 0x80)) else "MIN:SEC"
        chess_hint = f"   CHESS: Left[{l_unit}] | Right[{r_unit}]"
    return (
        f"\x1b[H\x1b[96m WatchChip SoC — Terminal Clock (Backend Verilog: source/*.v + firmware/main.s)\x1b[K\x1b[0m\n\n"
        f"{ansi_col}{big}\x1b[0m\n\n"
        f"  [{line}]{chess_hint}   Màu LED: {ansi_col}{col_name:<8}\x1b[0m   "
        f"{'\x1b[93m♪ BEEP\x1b[0m' if beep else '      '}\x1b[K\n"
        f"  Chip chạy: {sim_s:8.2f} s   Tốc độ: x{speed:g}   Nút đang giữ: {held or '-':<5}\x1b[K\n\n"
        f"  Phím: [M] MODE   [A]   [B]   [C]   [1/2/4] Tốc độ   [Q] Thoát\x1b[K\n"
        f"  Vòng chế độ: TIME -> ALARM -> STOPWATCH -> TIMER -> SET\x1b[K\n"
    )


def get_key():
    """Đọc 1 phím không chặn (Windows dùng msvcrt; Linux/macOS dùng select + termios)."""
    if os.name == "nt":
        import msvcrt
        if msvcrt.kbhit():
            return msvcrt.getwch().lower()
        return None
    import select
    if select.select([sys.stdin], [], [], 0)[0]:
        return sys.stdin.read(1).lower()
    return None


def run_interactive(speed):
    """Vòng lặp chính giữ nhịp thời gian thực và truyền phím vào chân btn[3:0] của SoC."""
    global TAB
    TAB = seg7_codec.seg_table()
    chip = rtl_bridge.Chip()
    old = None
    if os.name != "nt":
        import termios
        import tty
        old = termios.tcgetattr(sys.stdin)
        tty.setcbreak(sys.stdin.fileno())

    queue = []
    cur_mask, hold_left, gap_left, held = 0, 0, 0, ""
    wall = time.perf_counter()
    try:
        sys.stdout.write("\x1b[2J\x1b[?25l")
        while True:
            k = get_key()
            while k:
                if k == "q":
                    return
                if k in ("1", "2", "4"):
                    speed = float(k)
                    wall = time.perf_counter()
                elif k in rtl_bridge.KEYS:
                    queue.append(k)
                k = get_key()

            if hold_left > 0:
                hold_left -= 1
                if hold_left == 0:
                    cur_mask, held, gap_left = 0, "", rtl_bridge.GAP_STEPS
            elif gap_left > 0:
                gap_left -= 1
            elif queue:
                key = queue.pop(0)
                cur_mask, held, hold_left = (
                    1 << rtl_bridge.KEYS[key],
                    key.upper(),
                    rtl_bridge.PRESS_STEPS,
                )

            t_ms, segs, color_idx, beep = chip.step(cur_mask, rtl_bridge.STEP_MS)
            sys.stdout.write(render(t_ms, segs, color_idx, beep, held, speed, chip.last_chess, chip.last_mode))
            sys.stdout.flush()

            wall += rtl_bridge.STEP_MS / 1000.0 / speed
            delay = wall - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            else:
                wall = time.perf_counter()
    finally:
        sys.stdout.write("\x1b[?25h\n")
        if old is not None:
            import termios
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
        chip.close()


# ----------------------------------------------------------------------------
# 3. KIỂM THỬ TỰ ĐỘNG ĐẦU-CUỐI (--selftest)
# ----------------------------------------------------------------------------
def selftest():
    """Bấm phím theo kịch bản, đối chiếu phản hồi thực tế lấy từ RTL và firmware."""
    global TAB
    TAB = seg7_codec.seg_table()
    chip = rtl_bridge.Chip()
    fails = []

    def frame(ms=200):
        t_ms, s, col, _ = chip.step(0, ms)
        return t_ms, s, col, seg7_codec.text(s, TAB, chess=chip.last_chess, mode=chip.last_mode).strip()

    def press(key, ms_after=300):
        for _ in range(rtl_bridge.PRESS_STEPS):
            chip.step(1 << rtl_bridge.KEYS[key], rtl_bridge.STEP_MS)
        chip.step(0, ms_after)

    def check(cond, what, got):
        print(("  ok   " if cond else "  LOI  ") + f"{what}: {got}")
        if not cond:
            fails.append(what)

    t0, _, c0, x0 = frame(500)
    check(bool(x0), "TIME: màn hình có hiển thị (RTL + firmware chạy)", x0)
    t1, _, _, x1 = frame(3000)
    check(x1 != x0 and t1 > t0, "TIME: số đổi theo thời gian chip", f"{x0!r} -> {x1!r}")
    press("b")
    _, _, _, x2 = frame()
    check(x2 != x1, "TIME + nút B: chuyển kiểu xem", f"{x1!r} -> {x2!r}")
    press("c")
    _, _, c1, _ = frame()
    check(c1 == ((c0 + 1) & 3), "TIME + nút C: đổi màu LED thật từ firmware (V_COLOR)", f"{c0} -> {c1}")

    modes = []
    for _ in range(4):
        press("m")
        _, _, _, x = frame()
        modes.append(x)
    check(len(set(modes)) == len(modes), "MODE x4: đi qua ALARM/STOPWATCH/TIMER/SET", modes)
    chip.close()

    # Phiên chip mới ở TIME: MODE x2 -> STOPWATCH, A chạy -> kiểm chữ số 1/1000s nhảy mượt -> A dừng
    chip = rtl_bridge.Chip()
    chip.step(0, 500)
    press("m")
    press("m")
    _, _, _, sw0 = frame(300)
    press("a", ms_after=100)
    last_digits = []
    for _ in range(8):
        _, s, _, _ = chip.step(0, rtl_bridge.STEP_MS)
        txt = seg7_codec.text(s, TAB).strip()
        if txt:
            last_digits.append(txt[-1])
    _, _, _, sw_run = frame(1000)
    check(
        len(set(last_digits)) >= 4 and sw_run != sw0,
        "STOPWATCH + nút A: chạy & nhảy chữ số 1/1000 s",
        f"digits={last_digits}, -> {sw_run!r}",
    )
    press("a")
    _, _, _, sw3 = frame(400)
    _, _, _, sw4 = frame(800)
    check(sw3 == sw4, "STOPWATCH + nút A lần 2: dừng chính xác", f"{sw3!r} == {sw4!r}")
    chip.close()

    print("TẤT CẢ PASS" if not fails else f"CÓ {len(fails)} LỖI: {fails}")
    return 0 if not fails else 1


def main():
    """Điểm vào CLI: tự build khi cần rồi chạy giao diện terminal hoặc selftest."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--speed", type=float, default=1.0, help="tốc độ so với thời gian thật (mặc định 1)")
    ap.add_argument("--selftest", action="store_true", help="tự bấm phím kiểm backend RTL rồi thoát")
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    rtl_bridge.ensure_built()
    if a.selftest:
        sys.exit(selftest())
    run_interactive(a.speed)


if __name__ == "__main__":
    main()
