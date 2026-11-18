# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/tests/hazard/load_use.s — Kiểm Thử Pipeline G2: Xung Đột Load-Use Hazard
# CHUYÊN ĐỀ KTMT: Chương 04: Bộ Phát Hiện Xung Đột Dữ Liệu (Hazard Detection Unit & 1-Cycle Stall)
# VAI TRÒ:        Kiểm chứng cơ chế chèn đúng 1 bọt khí khi lệnh ngay sau lw dùng kết quả vừa nạp
# MÔ TẢ:          Bao quát cả phụ thuộc rs, rt, ngoại lệ lw->sw (MEM-MEM forward) và ghi đè đích rt (bubbles = 3).
# ============================================================================
# B6 load_use — load-use 1 bubble với rs, với rt, lw→sw cùng thanh ghi; lw→addiu dùng rt làm đích (0);
# lw rồi cách 1 lệnh (0). Theo pipeline-policy §4, T2.
# bubbles 3
# expect $t0=100
# expect $t1=200
# expect $t4=107
# expect $t6=9
# expect $s2=200
        li    $t2, 100
        li    $t9, 7
        sw    $t2, 0x800($zero)     # M[800] = 100
        sw    $t9, 0x804($zero)     # M[804] = 7
        sw    $t9, 0x808($zero)     # M[808] = 7
        sw    $t2, 0x810($zero)     # M[810] = 100
        lw    $t0, 0x800($zero)     # t0 = 100
        addu  $t1, $t0, $t2         # rs phụ thuộc load: stall 1 → t1 = 200
        lw    $t3, 0x804($zero)     # t3 = 7
        addu  $t4, $t2, $t3         # rt phụ thuộc load: stall 1 → t4 = 107
        lw    $t5, 0x808($zero)     # t5 = 7
        sw    $t5, 0x80c($zero)     # rt của sw phụ thuộc load: stall 1 (M[80c] = 7)
        lw    $t6, 0x810($zero)     # t6 = 100
        addiu $t6, $zero, 9         # rt là đích, không đọc: KHÔNG stall → t6 = 9
        lw    $t8, 0x800($zero)     # t8 = 100
        addu  $t9, $zero, $zero     # lệnh độc lập ở giữa
        addu  $s2, $t8, $t8         # cách 2 lệnh: 0 stall (forward 01) → 200
