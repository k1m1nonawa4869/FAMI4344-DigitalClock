# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/tests/hazard/bcd_busy.s — Kiểm Thử Pipeline G2: Lệnh BCD Đa Chu Kỳ
# CHUYÊN ĐỀ KTMT: Chương 04: Pipeline Stall Cho Đơn Vị Thực Thi Tuần Tự (Multi-cycle Stall)
# VAI TRÒ:        Đo chính xác số chu kỳ bọt khí (bubbles = 54) khi chạy lệnh bcd thường và bcd tràn
# MÔ TẢ:          Xác nhận hợp lệ 27 bọt khí cho trường hợp thường và 0 bọt khí cho trường hợp tràn nhanh.
# ============================================================================
# B6 bcd_busy — bcd tuần tự: 28 chu kỳ EX (+27 bubble) khi kết quả ≤ 99 999 999; tràn: 1 chu kỳ (+0).
# Ca: bcd(1234) +27; bcd(100000000) tràn → 0xFFFFFFFF +0; bcd(4567) +27. Tổng 54 (pipeline-policy §6, T8).
# bubbles 54
# expect $t0=0x1234
# expect $t1=0xffffffff
# expect $t3=0x4567
# expect $t4=0x579b
        li    $s0, 1234
        bcd   $t0, $s0              # t0 = 0x1234; sw ngay sau dùng forward
        sw    $t0, 0x800($zero)     # M[800] = 0x1234
        li    $s2, 100000000        # > 99 999 999
        bcd   $t1, $s2              # tràn: 0xFFFFFFFF, không bận
        li    $s3, 4567
        bcd   $t3, $s3              # t3 = 0x4567
        addu  $t4, $t3, $t0         # 0x4567 + 0x1234 = 0x579B (forward 10 từ bcd)
