# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/exp/e3_poll.s — Thực Nghiệm E3: Bắt Sự Kiện Bằng Thăm Dò (Polling)
# CHUYÊN ĐỀ KTMT: Chương 05: Hệ Thống Vào/Ra & Phân Tích Độ Trễ Phản Hồi (Polling vs Interrupt)
# VAI TRÒ:        Đo độ trễ (Latency) từ lúc bấm nút B đến khi vòng lặp chính kiểm tra được BTN_EVENT
# MÔ TẢ:          Thực hiện khối lượng công việc nền tương đương e3_irq.s để so sánh công bằng với cơ chế ngắt.
# ============================================================================
# e3_poll.s — thí nghiệm E3 (chủ TV3 + TV2), cách 1: POLLING. tb/exp_e3_tb.v bấm nút B, đo lúc firmware có MS_OF_DAY.
# Vòng chính = kiểm BTN_EVENT + việc nền W (div + 4 lệnh ALU, giống firmware thật có div khi định dạng số).
# Stopwatch SRC = 1, RUN = 1 → mỗi lần B phần cứng chụp lap (cách 3), firmware chỉ lấy ra khỏi FIFO.
# D (CPU_CLK_DIV) do tools/exp_e3.py thay vào dòng .eqv dưới.
        .eqv  D_VAL 2
        j     main

        .org  0x180
handler:
        eret                            # không bật ngắt

main:   addiu $t0, $zero, D_VAL
        sw    $t0, -116($zero)          # CPU_CLK_DIV = D
        addiu $t0, $zero, 1
        sw    $t0, -228($zero)          # SW_CTRL: SRC = 0, RUN = 1
        addiu $t0, $zero, 4
        sw    $t0, -228($zero)          # SRC = 1 (RUN giữ) → nút A/B điều khiển phần cứng
        addiu $t5, $zero, 7
        addiu $t0, $zero, 1
        sw    $t0, 0($zero)             # DMEM[0] = 1: báo tb bắt đầu bấm
poll:   lw    $t1, -192($zero)          # BTN_EVENT (đọc thì lấy ra), [31] VALID
        slt   $t2, $t1, $zero
        beq   $t2, $zero, work
        lw    $t3, -252($zero)          # cách 1: MS_OF_DAY lúc firmware thấy nút
        lw    $t4, -220($zero)          # lấy lap khỏi FIFO (tb đọc giá trị)
work:   div   $t5, $t5                  # việc nền W
        addu  $t6, $t6, $t5
        addu  $t7, $t7, $t6
        addu  $t8, $t8, $t7
        addu  $t9, $t9, $t8
        j     poll
