# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/tests/cpu/hazard.s — Kiểm Thử Phụ Thuộc Dữ Liệu Tức Thời (RAW Hazard)
# CHUYÊN ĐỀ KTMT: Chương 04: Thiết Kế Đường Dữ Liệu CPU G1 & Tương Tác Ghi-Đọc Tập Thanh Ghi
# VAI TRÒ:        Xác nhận lệnh ghi thanh ghi và lệnh kế tiếp đọc ngay lập tức hoạt động chính xác
# MÔ TẢ:          Kiểm tra chuỗi phụ thuộc Read-After-Write liên tiếp giữa các lệnh ALU và nạp dữ liệu.
# ============================================================================
# C3-5: ghi rồi đọc ngay ở lệnh sau (G1 regfile không bypass, ghi ở pha A)
        li    $t1, 0x7f0
        li    $t0, 0x10
        addu  $t0, $t0, $t1         # $t0 = 0x800
        li    $t2, 0x900
        sw    $t2, 0($t0)           # M[0x800] = 0x900
        lw    $t0, 0($t0)           # $t0 = 0x900 (dùng ngay $t0 vừa ghi)
        lw    $t3, 0($t0)           # M[0x900] = 0
        addiu $t3, $t0, 1
        sw    $t3, 0($t0)
        lw    $t4, 0($t0)
        jal   f
        addu  $s0, $ra, $zero
        j     end
f:      addu  $s1, $ra, $zero       # đọc $ra ngay sau jal
        jr    $ra
end:    nop
