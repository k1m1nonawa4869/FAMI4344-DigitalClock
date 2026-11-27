# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    testbench/sim_tools/screen.py — Bộ trực quan hóa màn hình hiển thị LED 7 đoạn & Terminal
# CHUYÊN ĐỀ KTMT: Chương 05: Hệ thống Vào/Ra (I/O) & Ngoại vi hiển thị đa hợp (Multiplexed Display)
# VAI TRÒ:        Đọc log quét hiển thị phần cứng từ screen_dump.v, tái tạo trực quan trạng thái đồng hồ trên terminal.
# MÔ TẢ:          - Đọc file vết screen.log thu thập từ các chân vật lý Anode và Cathode trong mô phỏng Verilog.
#                 - Giải mã mẫu 7 đoạn thành ký tự ASCII (0-9, A-F, ký hiệu đặc biệt) đối chiếu bảng mã seg7.
#                 - Xuất chuỗi hiển thị theo thời gian thực (ms) hoặc vẽ chữ số 7 đoạn kích thước lớn (--big).
#                 - Hỗ trợ xuất ảnh tĩnh PNG hoặc ảnh động GIF trực quan hóa toàn bộ quá trình vận hành đồng hồ.
# ============================================================================

"""Màn hình ảo (gói D7): đọc log của tb/screen_dump.v → in ra terminal hoặc vẽ GIF/PNG.

  python testbench/sim_tools/screen.py work/screen_clock.log              # mỗi ảnh 1 dòng chữ:  t=  1234 ms |   23.59.58
  python testbench/sim_tools/screen.py work/screen_clock.log --big        # vẽ 7 đoạn to bằng ký tự
  python testbench/sim_tools/screen.py work/screen_clock.log --gif work/clock.gif [--speed 1]
  python testbench/sim_tools/screen.py work/screen_clock.log --png work/clock.png   # ảnh cuối

Giải mã đoạn → ký tự theo testbench/vectors/seg7.txt (5 và S cùng mẫu → in '5').
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHARS = "0123456789AbCdEFHLnoPrStU- MWG"
# ảnh tồn tại < TEAR_MS là "xé hình": firmware đang ghi dở 8 ô thì bộ quét chụp đúng 1 vòng
# (mô phỏng: 1 vòng = 40 × 8 chu kỳ = 6,4 ms theo G_N = 50; chip thật 8 ms, mắt không thấy).
# Ảnh thật đổi chậm nhất 250 ms (nháy) nên ngưỡng 10 ms tách được. Chế độ chữ đánh dấu, GIF/PNG bỏ qua.
TEAR_MS = 10


_SEG_TAB_CACHE = None


def seg_table():
    """Đọc và cache bảng ánh xạ mẫu 7 đoạn (gfedcba) -> ký tự ASCII từ testbench/vectors/seg7.txt."""
    global _SEG_TAB_CACHE
    if _SEG_TAB_CACHE is not None:
        return _SEG_TAB_CACHE
    t = {}
    with open(os.path.join(ROOT, "testbench", "vectors", "seg7.txt"), encoding="utf-8") as f:
        for ln in f:
            if ln.startswith("#") or not ln.strip():
                continue
            code, pat = (int(x, 16) for x in ln.split()[:2])
            if code < len(CHARS) and pat not in t:
                t[pat] = CHARS[code]
    t[0] = " "
    _SEG_TAB_CACHE = t
    return t


def load(path):
    """Đọc file vết quét chân LED từ tb/screen_dump.v thành danh sách (timestamp_ms, segs)."""
    frames = []
    with open(path, encoding="utf-8") as f:
        for ln in f:
            if ln.startswith("#") or not ln.strip():
                continue
            p = ln.split()
            t, segs, lit = int(p[0]), [int(x, 16) for x in p[1:-1]], int(p[-1], 16)
            n = len(segs)
            # segs[0] = S7 (trái) … segs[-1] = S0 (phải); chữ số tắt (LIT = 0) coi như trống
            segs = [s if (lit >> (n - 1 - k)) & 1 else 0 for k, s in enumerate(segs)]
            frames.append((t, segs))
    return frames


def _detect_chess(c, dp):
    """Xác định khung hình 8 chữ số có phải chế độ đồng hồ cờ vua kép (Left | Right) hay không."""
    is_ampm = (c[0] in ('A', 'P') and c[1] == 'M') or (c[0] == ' ' and c[1] in ('A', 'P'))
    is_date = dp[1] and dp[3] and not dp[5] and not dp[7] and "".join(c[4:]).isdigit() and len("".join(c[4:])) == 4
    is_time24 = dp[1] and dp[3] and dp[5] and not dp[7] and all(x.isdigit() for x in c)
    # Stopwatch / Timer single live clock: dp[2] và dp[4] bật
    is_live_clock = dp[2] and dp[4] and "".join(c[1:]).isdigit()
    # Chess Clock: cả 2 đồng hồ đấu thủ đều gồm 4 chữ số độc lập (hoặc dấu trừ ở đầu)
    is_left_chess = (c[0] == '-' and "".join(c[1:4]).isdigit()) or "".join(c[0:4]).isdigit()
    is_right_chess = (c[4] == '-' and "".join(c[5:8]).isdigit()) or "".join(c[4:8]).isdigit()
    return (
        not is_ampm
        and not is_date
        and not is_time24
        and not is_live_clock
        and is_left_chess
        and is_right_chess
        and (dp[1] or dp[3])
        and (dp[5] or dp[7])
    )


def text(segs, tab):
    """Giải mã một khung hình LED 7 đoạn sang chuỗi văn bản ngắn gọn khớp chế độ đồng hồ."""
    if len(segs) != 8:
        out = ""
        for s in segs:
            out += tab.get(s & 0x7F, "?") + ("." if s & 0x80 else "")
        return out

    c = [tab.get(s & 0x7F, "?") for s in segs]
    dp = [(s & 0x80) != 0 for s in segs]

    # 1. Nhận diện chế độ Chess Clock (Left | Right)
    if _detect_chess(c, dp):
        # Bên Trái: nếu có chấm ở dp[1] và không có dp[3] -> MM:SS; nếu dp[3] bật -> SS.cs
        if dp[1] and not dp[3]:
            left_str = f"{c[0]}{c[1]}:{c[2]}{c[3]}"
        elif dp[1] and dp[3]:
            left_str = f"{c[0]}{c[1]}.{c[2]}{c[3]}."
        elif dp[3]:
            left_str = f"{c[0]}{c[1]}.{c[2]}{c[3]}"
        else:
            left_str = f"{c[0]}{c[1]}{c[2]}{c[3]}"

        # Bên Phải: tương tự
        if dp[5] and not dp[7]:
            right_str = f"{c[4]}{c[5]}:{c[6]}{c[7]}"
        elif dp[5] and dp[7]:
            right_str = f"{c[4]}{c[5]}.{c[6]}{c[7]}."
        elif dp[7]:
            right_str = f"{c[4]}{c[5]}.{c[6]}{c[7]}"
        else:
            right_str = f"{c[4]}{c[5]}{c[6]}{c[7]}"

        return f"{left_str} | {right_str}"

    # 2. Nhận diện chế độ 99 Laps Stopwatch: [L##] MM:SS.cc
    if c[0].isdigit() and c[1].isdigit() and dp[3] and dp[5] and not dp[0] and not dp[1]:
        return f"[{c[0]}{c[1]}] {c[2]}{c[3]}:{c[4]}{c[5]}.{c[6]}{c[7]}"

    # 3. Nhận diện chế độ 12H AM/PM: AM 10:25:30
    if (c[0] in ('A', 'P') and c[1] == 'M') or (c[0] == ' ' and c[1] in ('A', 'P')):
        prefix = f"{c[0]}{c[1]} "
        sep1 = ":" if dp[3] else " "
        sep2 = ":" if dp[5] else " "
        return f"{prefix}{c[2]}{c[3]}{sep1}{c[4]}{c[5]}{sep2}{c[6]}{c[7]}"

    # 4. Nhận diện chế độ 24H + CS hoặc HH:MM:SS.cs
    if dp[1] and dp[3] and dp[5]:
        return f"{c[0]}{c[1]}:{c[2]}{c[3]}:{c[4]}{c[5]}.{c[6]}{c[7]}"

    # 5. Nhận diện chế độ H:MM:SS.mmm (Stopwatch / Timer single live)
    # c[0] = H hoặc ' ' hoặc '-', c[1..2] = MM, c[3..4] = SS, c[5..7] = mmm (dp ở vị trí index 2 và 4 từ trái qua)
    if dp[2] and dp[4] and not dp[0] and not dp[1] and not dp[3] and not dp[5] and not dp[6] and not dp[7]:
        if "".join(c[1:]).isdigit():
            sep_h = ":" if c[0].isdigit() else " "
            return f"{c[0]}{sep_h}{c[1]}{c[2]}:{c[3]}{c[4]}.{c[5]}{c[6]}{c[7]}"

    # Mặc định ghép chuỗi nối tiếp
    out = ""
    for s in segs:
        out += tab.get(s & 0x7F, "?") + ("." if s & 0x80 else "")
    return out


def big(segs, tab=None):
    """Vẽ chữ số 7 đoạn cỡ lớn bằng ký tự ASCII (3 dòng), chèn vách ngăn | khi ở chế độ Chess Clock."""
    rows = ["", "", ""]
    n = len(segs)
    is_chess = False
    if n == 8:
        if tab is None:
            tab = seg_table()
        chars = [tab.get(s & 0x7F, "?") for s in segs]
        dp = [(s & 0x80) != 0 for s in segs]
        is_chess = _detect_chess(chars, dp)

    for k, s in enumerate(segs):
        sa, sb, sc, sd, se, sf, sg = ((s >> i) & 1 for i in range(7))
        rows[0] += " " + ("_" if sa else " ") + "  "
        rows[1] += ("|" if sf else " ") + ("_" if sg else " ") + ("|" if sb else " ") + " "
        rows[2] += ("|" if se else " ") + ("_" if sd else " ") + ("|" if sc else " ") + ("." if s & 0x80 else " ")
        # Chèn vách ngăn | nổi bật giữa Left Clock (D4) và Right Clock (D3)
        if is_chess and k == 3:
            rows[0] += "   |   "
            rows[1] += "   |   "
            rows[2] += "   |   "
    return "\n".join(rows)


def draw(segs, scale=6):
    """Vẽ khung hình LED 7 đoạn thành ảnh PIL RGB (phục vụ xuất PNG/GIF)."""
    from PIL import Image, ImageDraw
    W, H, T = 10 * scale, 18 * scale, 2 * scale     # kích thước 1 chữ số, độ dày đoạn
    pad = 3 * scale
    img = Image.new("RGB", (pad * 2 + len(segs) * (W + pad), H + pad * 2), (12, 12, 12))
    d = ImageDraw.Draw(img)
    on, off = (255, 40, 20), (45, 20, 18)
    for k, s in enumerate(segs):
        x0, y0 = pad + k * (W + pad), pad
        boxes = [  # a b c d e f g
            (x0 + T, y0, x0 + W - T, y0 + T),
            (x0 + W - T, y0 + T, x0 + W, y0 + H // 2),
            (x0 + W - T, y0 + H // 2, x0 + W, y0 + H - T),
            (x0 + T, y0 + H - T, x0 + W - T, y0 + H),
            (x0, y0 + H // 2, x0 + T, y0 + H - T),
            (x0, y0 + T, x0 + T, y0 + H // 2),
            (x0 + T, y0 + H // 2 - T // 2, x0 + W - T, y0 + H // 2 + T // 2),
        ]
        for i, bx in enumerate(boxes):
            d.rectangle(bx, fill=on if (s >> i) & 1 else off)
        d.ellipse((x0 + W + T // 2, y0 + H - T, x0 + W + T // 2 + T, y0 + H), fill=on if s & 0x80 else off)
    return img


def main():
    """Điểm vào CLI: phân tích đối số và xuất màn hình ảo ra terminal / PNG / GIF."""
    sys.stdout.reconfigure(encoding="utf-8")   # console Windows cp1252 không in được help tiếng Việt
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--big", action="store_true")
    ap.add_argument("--gif")
    ap.add_argument("--png")
    ap.add_argument("--speed", type=float, default=1.0, help="1 = thời gian thật mô phỏng")
    a = ap.parse_args()
    frames = load(a.log)
    if not frames:
        sys.exit("log rong")
    tab = seg_table()
    ends = [t for t, _ in frames[1:]] + [None]
    torn = [e is not None and e - t < TEAR_MS for (t, _), e in zip(frames, ends)]
    if not (a.gif or a.png):
        for (t, segs), x in zip(frames, torn):
            if a.big:
                print(f"t = {t} ms\n{big(segs, tab)}\n")
            else:
                print(f"t={t:>7} ms | {text(segs, tab):<12}" + ("  <- xe hinh (ghi do, 1 vong quet)" if x else ""))
    frames = [f for f, x in zip(frames, torn) if not x]
    if a.png:
        draw(frames[-1][1]).save(a.png)
        print("da ghi", a.png)
    if a.gif:
        imgs = [draw(s) for _, s in frames]
        times = [t for t, _ in frames] + [frames[-1][0] + 1000]
        durs = [max(20, int((times[k + 1] - times[k]) / a.speed)) for k in range(len(frames))]
        imgs[0].save(a.gif, save_all=True, append_images=imgs[1:], duration=durs, loop=0)
        print(f"da ghi {a.gif}: {len(imgs)} anh, {sum(durs) / 1000:.1f} s")


if __name__ == "__main__":
    main()
