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
def _is_half_chess_chars(sub_chars):
    """Kiểm tra 4 ký tự một nửa màn hình có hợp lệ cho Chess (MMSS, SScc hoặc -Scc)."""
    s = "".join(sub_chars)
    if s[0] == "-" and s[1:].isdigit():
        return True
    return s.isdigit()


def detect_chess(chars, dp, chess=None, mode=None):
    """Kiểm tra 8 chữ số có đang hiển thị Đồng hồ Cờ vua kép (Trái | Phải) hay không."""
    if chess is not None:
        return bool(chess) and _is_half_chess_chars(chars[0:4]) and _is_half_chess_chars(chars[4:8])
    if mode is not None and mode != 3:
        return False
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
    # 24h+cs chỉ hợp lệ nếu HH <= 23 và MM <= 59; Chess < 1m | >= 1m có thể có SS >= 24 hoặc d3==1
    hh_valid = chars[0].isdigit() and chars[1].isdigit() and int(chars[0] + chars[1]) <= 23
    mm_valid = chars[2].isdigit() and chars[3].isdigit() and int(chars[2] + chars[3]) <= 59
    is_time24 = dp[1] and dp[3] and dp[5] and not dp[7] and all(x.isdigit() for x in chars) and hh_valid and mm_valid
    is_live_clock = dp[2] and dp[4] and "".join(chars[1:]).isdigit()
    is_left = _is_half_chess_chars(chars[0:4])
    is_right = _is_half_chess_chars(chars[4:8])
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


def _classify_seps(chars, dp, is_chess):
    """Phân loại dấu tách cho từng vị trí 0..7: '' (ẩn), '.' (thập phân), ':' (hai chấm giờ:phút)."""
    seps = ["." if d else "" for d in dp]
    if len(chars) != 8:
        return seps

    if is_chess:
        # Nửa Trái (0..3) và Nửa Phải (4..7):
        #   dp[k+1]=1, dp[k+3]=0 -> MM:SS (hai chấm ':')
        #   dp[k+1]=1, dp[k+3]=1 -> SS.cc hoặc -S.cc (một chấm '.', ẩn chấm đuôi kỹ thuật ở k+3)
        for base in (0, 4):
            if dp[base + 1] and not dp[base + 3]:
                seps[base + 1] = ":"
                seps[base + 3] = ""
            elif dp[base + 1] and dp[base + 3]:
                seps[base + 1] = "."
                seps[base + 3] = ""
        return seps

    # 99-Lap viewing mode: [LL] MM:SS.cc (dp3 & dp5, không có dp1)
    if chars[0].isdigit() and chars[1].isdigit() and dp[3] and dp[5] and not dp[0] and not dp[1] and not dp[7]:
        seps[3] = ":"
        seps[5] = "."
        return seps

    # 12h AM/PM: AM HH:MM:SS
    if (chars[0] in ("A", "P") and chars[1] == "M") or (chars[0] == " " and chars[1] in ("A", "P")):
        if dp[3]:
            seps[3] = ":"
        if dp[5]:
            seps[5] = ":"
        return seps

    # 24h+cs: HH:MM:SS.cc
    if dp[1] and dp[3] and dp[5] and not dp[7] and all(x.isdigit() for x in chars):
        seps[1] = ":"
        seps[3] = ":"
        seps[5] = "."
        return seps

    # ALARM / SET MM:SS (AL1o HH:MM hoặc C2  MM:SS): dấu chấm đơn ở dp5 hoặc dp3+dp5
    if chars[0] == "A" and chars[1] == "L" and dp[5] and not dp[1] and not dp[3]:
        seps[5] = ":"
        return seps

    # STOPWATCH / TIMER H:MM:SS.mmm (dp2 & dp4, có thể kèm dp0 hoặc dấu '-' ở chars[0])
    if dp[2] and dp[4] and not any((dp[1], dp[3], dp[5], dp[6], dp[7])):
        if "".join(chars[1:]).isdigit():
            seps[0] = ":" if (dp[0] or chars[0].isdigit()) else ""
            seps[2] = ":"
            seps[4] = "."
            return seps

    return seps


def text(segs, tab=None, chess=None, mode=None):
    """Giải mã mảng 8 byte {dp, gfedcba} sang chuỗi văn bản 1 dòng dễ đọc."""
    if tab is None:
        tab = seg_table()
    if len(segs) != 8:
        return "".join(tab.get(s & 0x7F, "?") + ("." if s & 0x80 else "") for s in segs)

    c = [tab.get(s & 0x7F, "?") for s in segs]
    dp = [(s & 0x80) != 0 for s in segs]

    if detect_chess(c, dp, chess=chess, mode=mode):
        def _half(idxs, d1, d2):
            raw = "".join(c[i] for i in idxs)
            if d1 and not d2:
                return f"{raw[:2]}:{raw[2:]}"
            if d1 and d2:
                return f"{raw[:2]}.{raw[2:]}"
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
# 3. VẼ KHUNG LED 7 ĐOẠN CỠ LỚN BẢNG KÝ TỰ ASCII (CHO TERMINAL)
# ----------------------------------------------------------------------------
def big(segs, tab=None, chess=None, mode=None):
    """Vẽ 8 chữ số 7 đoạn thành chuỗi 3 dòng ASCII (phân biệt ':' với '.', tự chèn vách '|' ở Chess Clock)."""
    rows = ["", "", ""]
    n = len(segs)
    is_chess = False
    seps = ["." if (s & 0x80) else "" for s in segs]
    if n == 8:
        if tab is None:
            tab = seg_table()
        chars = [tab.get(s & 0x7F, "?") for s in segs]
        dp = [(s & 0x80) != 0 for s in segs]
        is_chess = detect_chess(chars, dp, chess=chess, mode=mode)
        seps = _classify_seps(chars, dp, is_chess)

    for k, s in enumerate(segs):
        sa, sb, sc, sd, se, sf, sg = ((s >> i) & 1 for i in range(7))
        sep = seps[k]
        r1_sep = "." if sep == ":" else " "
        r2_sep = "." if sep in (".", ":") else " "
        rows[0] += " " + ("_" if sa else " ") + "  "
        rows[1] += ("|" if sf else " ") + ("_" if sg else " ") + ("|" if sb else " ") + r1_sep
        rows[2] += ("|" if se else " ") + ("_" if sd else " ") + ("|" if sc else " ") + r2_sep
        if is_chess and k == 3:
            rows[0] += "   |   "
            rows[1] += "   |   "
            rows[2] += "   |   "
    return "\n".join(rows)
