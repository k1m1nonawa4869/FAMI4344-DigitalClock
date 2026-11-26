# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/tests/cpu/sum100.s — Kiểm Thử Vòng Lặp Cơ Bản Tính Tổng 1..100
# CHUYÊN ĐỀ KTMT: Chương 02: Điều Khiển Luồng Lệnh (Loops & Conditional Branching)
# VAI TRÒ:        Bài test smoke kinh điển xác nhận khả năng chạy vòng lặp và cộng dồn của CPU
# MÔ TẢ:          Cộng dồn giá trị từ 1 đến 100 sử dụng bne rẽ nhánh lùi, kết quả mong đợi $v0 = 5050.
# ============================================================================
# C3-2: tổng 1..100 → $v0 = 5050 (vòng lặp nhánh lùi)
# expect $v0=5050
        li    $v0, 0
        li    $t0, 1
        li    $t1, 101
loop:   addu  $v0, $v0, $t0
        addiu $t0, $t0, 1
        bne   $t0, $t1, loop
        sw    $v0, 0x800($zero)
