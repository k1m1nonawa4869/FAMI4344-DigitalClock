#!/usr/bin/env python3
# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/seg7_codec.py — Bộ Giải Mã LED 7 Đoạn & Vẽ ASCII Thuần
# CHUYÊN ĐỀ KTMT: Chương 05: Hệ thống Vào/Ra (I/O) & Ngoại vi hiển thị đa hợp
# VAI TRÒ:        Cung cấp bảng mã 31 ký tự 7 đoạn khớp với src/char_rom.v,
#                 giải mã tín hiệu chân {dp, gfedcba} sang chuỗi văn bản hoặc
#                 khung LED ASCII cỡ lớn (--) dùng cho ứng dụng đồng hồ terminal.
# MÔ TẢ:          - Độc lập hoàn toàn với testbench/: nhúng trực tiếp 31 mẫu 7 đoạn
#                   (0..9, A..F, H, L, n, o, P, r, S, t, U, -, dấu cách, M, W, G).
#                 - Nhận diện thông minh các chế độ hiển thị: Chess Clock (Left | Right),
#                   12h AM/PM, 24h + centi-giây, 99-Lap Stopwatch và Live H:MM:SS.mmm.
#                 - Vẽ khung LED 7 đoạn 3 dòng bằng ký tự ASCII, tự chèn vách ngăn '|'
#                   chính giữa khi hiển thị đồng hồ cờ vua kép 4+4.
# ============================================================================
"""Bộ giải mã mẫu 7 đoạn dùng chung cho sản phẩm đồng hồ WatchChip (không phụ thuộc testbench/)."""

CHARS = "0123456789AbCdEFHLnoPrStU- MWG"

# ----------------------------------------------------------------------------
# 1. BẢNG TRA MẪU 7 ĐOẠN KHỚP CHÍNH XÁC VỚI src/char_rom.v
# ----------------------------------------------------------------------------
# Mỗi giá trị 7-bit là {g, f, e, d, c, b, a}, mức 1 = thanh đoạn sáng.
_CHAR_PATS = (
    0x3F,  # 0: 0
    0x06,  # 1: 1
    0x5B,  # 2: 2
    0x4F,  # 3: 3
    0x66,  # 4: 4
    0x6D,  # 5: 5 (cùng mẫu với S)
    0x7D,  # 6: 6
    0x07,  # 7: 7
    0x7F,  # 8: 8
    0x6F,  # 9: 9
    0x77,  # 10: A
    0x7C,  # 11: b
    0x39,  # 12: C
    0x5E,  # 13: d
    0x79,  # 14: E
    0x71,  # 15: F
    0x76,  # 16: H
    0x38,  # 17: L
    0x54,  # 18: n
    0x5C,  # 19: o
    0x73,  # 20: P
    0x50,  # 21: r
    0x6D,  # 22: S (trùng mẫu '5' trong 7-đoạn; tra cứu giữ nguyên ưu tiên '5')
    0x78,  # 23: t
    0x3E,  # 24: U
    0x40,  # 25: -
    0x00,  # 26: khoảng trắng
    0x37,  # 27: M
    0x1C,  # 28: W
    0x3D,  # 29: G
)

_SEG_TAB_CACHE = None


def seg_table():
    """Trả về dict ánh xạ mẫu 7-bit gfedcba -> ký tự ASCII."""
    global _SEG_TAB_CACHE
    if _SEG_TAB_CACHE is not None:
        return _SEG_TAB_CACHE
    tab = {}
    for code, pat in enumerate(_CHAR_PATS):
        if code < len(CHARS) and pat not in tab:
            tab[pat] = CHARS[code]
    tab[0] = " "
    _SEG_TAB_CACHE = tab
    return tab


# ----------------------------------------------------------------------------
# 2. NHẬN DIỆN CHẾ ĐỘ CỜ VUA & GIẢI MÃ KHUNG HÌNH 8 CHỮ SỐ
# ----------------------------------------------------------------------------
def detect_chess(chars, dp):
    """Kiểm tra 8 chữ số có đang hiển thị Đồng hồ Cờ vua kép (Trái | Phải) hay không."""
    is_ampm = (chars[0] in ("A", "P") and chars[1] == "M") or (
        chars[0] == " " and chars[1] in ("A", "P")
    )
    is_date = (
        dp[1]
        and dp[3]
        and not dp[5]
        and not dp[7]
        and "".join(chars[4:]).isdigit()
        and len("".join(chars[4:])) == 4
    )
    is_time24 = dp[1] and dp[3] and dp[5] and not dp[7] and all(x.isdigit() for x in chars)
    is_live_clock = dp[2] and dp[4] and "".join(chars[1:]).isdigit()
    is_left = (chars[0] == "-" and "".join(chars[1:4]).isdigit()) or "".join(chars[0:4]).isdigit()
    is_right = (chars[4] == "-" and "".join(chars[5:8]).isdigit()) or "".join(chars[4:8]).isdigit()
    return (
        not is_ampm
        and not is_date
        and not is_time24
        and not is_live_clock
        and is_left
        and is_right
        and (dp[1] or dp[3])
        and (dp[5] or dp[7])
    )


def text(segs, tab=None):
    """Giải mã mảng 8 byte {dp, gfedcba} sang chuỗi văn bản 1 dòng dễ đọc."""
    if tab is None:
        tab = seg_table()
    if len(segs) != 8:
        return "".join(tab.get(s & 0x7F, "?") + ("." if s & 0x80 else "") for s in segs)

    c = [tab.get(s & 0x7F, "?") for s in segs]
    dp = [(s & 0x80) != 0 for s in segs]

    if detect_chess(c, dp):
        def _half(idxs, d1, d2):
            raw = "".join(c[i] for i in idxs)
            if d1 and not d2:
                return f"{raw[:2]}:{raw[2:]}"
            if d1 and d2:
                return f"{raw[:2]}.{raw[2:]}."
            if d2:
                return f"{raw[:2]}.{raw[2:]}"
            return raw

        return f"{_half((0, 1, 2, 3), dp[1], dp[3])} | {_half((4, 5, 6, 7), dp[5], dp[7])}"

    if c[0].isdigit() and c[1].isdigit() and dp[3] and dp[5] and not dp[0] and not dp[1]:
        return f"[{c[0]}{c[1]}] {c[2]}{c[3]}:{c[4]}{c[5]}.{c[6]}{c[7]}"

    if (c[0] in ("A", "P") and c[1] == "M") or (c[0] == " " and c[1] in ("A", "P")):
        s1 = ":" if dp[3] else " "
        s2 = ":" if dp[5] else " "
        return f"{c[0]}{c[1]} {c[2]}{c[3]}{s1}{c[4]}{c[5]}{s2}{c[6]}{c[7]}"

    if dp[1] and dp[3] and dp[5]:
        return f"{c[0]}{c[1]}:{c[2]}{c[3]}:{c[4]}{c[5]}.{c[6]}{c[7]}"

    if dp[2] and dp[4] and not any((dp[0], dp[1], dp[3], dp[5], dp[6], dp[7])):
        if "".join(c[1:]).isdigit():
            sep_h = ":" if c[0].isdigit() else " "
            return f"{c[0]}{sep_h}{c[1]}{c[2]}:{c[3]}{c[4]}.{c[5]}{c[6]}{c[7]}"

    return "".join(tab.get(s & 0x7F, "?") + ("." if s & 0x80 else "") for s in segs)


# ----------------------------------------------------------------------------
# 3. VẼ KHUNG LED 7 ĐOẠN CỠ LỚN BẰNG KÝ TỰ ASCII (CHO TERMINAL)
# ----------------------------------------------------------------------------
def big(segs, tab=None):
    """Vẽ 8 chữ số 7 đoạn thành chuỗi 3 dòng ASCII (tự chèn vách '|' khi ở Chess Clock)."""
    rows = ["", "", ""]
    n = len(segs)
    is_chess = False
    if n == 8:
        if tab is None:
            tab = seg_table()
        chars = [tab.get(s & 0x7F, "?") for s in segs]
        dp = [(s & 0x80) != 0 for s in segs]
        is_chess = detect_chess(chars, dp)

    for k, s in enumerate(segs):
        sa, sb, sc, sd, se, sf, sg = ((s >> i) & 1 for i in range(7))
        rows[0] += " " + ("_" if sa else " ") + "  "
        rows[1] += ("|" if sf else " ") + ("_" if sg else " ") + ("|" if sb else " ") + " "
        rows[2] += ("|" if se else " ") + ("_" if sd else " ") + ("|" if sc else " ") + ("." if s & 0x80 else " ")
        if is_chess and k == 3:
            rows[0] += "   |   "
            rows[1] += "   |   "
            rows[2] += "   |   "
    return "\n".join(rows)
