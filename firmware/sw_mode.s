# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/sw_mode.s — Xử Lý Chế Độ Bấm Giờ Thể Thao (STOPWATCH Mode)
# VAI TRÒ:        Xử lý sự kiện nút bấm và hiển thị chế độ STOPWATCH:
#                 Đồng bộ phần cứng chụp Lap với độ trễ 0 ns, lưu trữ mảng
#                 8 Lap trong DMEM và duyệt xem lại từng vòng bấm giờ.
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Đo Lường Thời Gian Thực Tế Không Trễ (Zero-Latency Hardware Capture):
#      Khi ở chế độ STOPWATCH, cờ SRC = 1 kết nối nút A và B trực tiếp vào
#      khối stopwatch_core ở tầng phần cứng RTL. Thời điểm bấm giờ được chốt
#      ngay tại sườn xung clock đầu tiên, triệt tiêu hoàn toàn độ trễ trễ quét (polling latency)
#      và độ trễ phục vụ ngắt của phần mềm.
#    - Hàng Đợi Vòng Tròn 8 Phần Tử (8-Entry Circular FIFO Buffer):
#      Phần cứng tự động lưu các giá trị Lap vào FIFO. Phần mềm đọc cạn FIFO
#      bằng cách kiểm tra bit dấu (MSB) của thanh ghi REG_SW_LAP.
# ============================================================================

# ----------------------------------------------------------------------------
# 1. XỬ LÝ SỰ KIỆN NÚT BẤM TRONG CHẾ ĐỘ STOPWATCH
# ----------------------------------------------------------------------------
sw_btn: addiu $t1, $zero, 2
        beq   $a0, $t1, sw_b
        addiu $t1, $zero, 3
        beq   $a0, $t1, sw_c
        sw    $zero, V_LAPI($zero)      # Nút A: Bật/Dừng chạy thực (hủy chế độ xem Lap)
        jr    $ra
sw_b:   lw    $t0, REG_SW_CTRL($zero)
        andi  $t0, $t0, SW_BIT_EN       # Kiểm tra cờ RUN
        bne   $t0, $zero, sw_r          # Đang chạy: Phần cứng đã tự động chụp Lap
        addiu $t0, $zero, 6             # Đang dừng: Nút B thực hiện xóa (CLR=1, giữ SRC=1)
        sw    $t0, REG_SW_CTRL($zero)
        sw    $zero, V_LAPN($zero)      # Đặt lại số Lap đã lưu về 0
        sw    $zero, V_LAPI($zero)
sw_r:   jr    $ra
sw_c:   lw    $t1, V_LAPN($zero)
        bne   $t1, $zero, sw_c_browse   # Nếu đã có Lap: Duyệt xem lại các vòng Lap
        # Khi chưa có Lap (LAPN == 0): Nút C đảo chế độ 9 Lap (1 ms) <-> 99 Lap (10 ms)
        lw    $t0, V_SW_MODE($zero)
        addiu $t2, $zero, 1
        subu  $t0, $t2, $t0             # 1 - t0 (đảo giữa 0 và 1)
        sw    $t0, V_SW_MODE($zero)
        jr    $ra
sw_c_browse:
        lw    $t0, V_LAPI($zero)
        addiu $t0, $t0, 1
        slt   $t2, $t1, $t0
        beq   $t2, $zero, sw_c1
        addu  $t0, $zero, $zero         # Quá số Lap hiện có: Quay về xem giờ chạy trực tiếp
sw_c1:  sw    $t0, V_LAPI($zero)
        jr    $ra

# ----------------------------------------------------------------------------
# 2. XỬ LÝ VẼ MÀN HÌNH CHẾ ĐỘ STOPWATCH
# ----------------------------------------------------------------------------
dr_sw:  lw    $t0, REG_SW_LAP($zero)    # Rút hết các giá trị Lap từ FIFO phần cứng (tối đa 8 Lap)
        slt   $t1, $t0, $zero           # Bit 31 (VALID) = 1 nếu FIFO có dữ liệu hợp lệ
        beq   $t1, $zero, ds2           # FIFO rỗng: Chuyển sang vẽ màn hình
        lw    $t2, V_LAPN($zero)
        slti  $t1, $t2, 8
        bne   $t1, $zero, sw_save       # Chưa đầy 8 Lap: Lưu bình thường vào vị trí t2
        # Đã đầy 8 Lap: Dịch trượt mảng sang trái để chốt ping mới nhất vào cuối (Sliding Window)
        addiu $t5, $zero, 0x440
        addiu $t6, $zero, 0x45c
sw_shift:
        lw    $t7, 4($t5)
        sw    $t7, 0($t5)
        addiu $t5, $t5, 4
        bne   $t5, $t6, sw_shift
        addiu $t2, $zero, 7             # Đặt vị trí ghi ở phần tử cuối cùng (0x45c)
sw_save:
        lui   $t1, 0x1fff
        ori   $t1, $t1, 0xffff          # Mặt nạ 29-bit giá trị mili-giây
        and   $t0, $t0, $t1
        sll   $t3, $t2, 2
        sw    $t0, V_LAPV($t3)          # Lưu giá trị Lap vào mảng V_LAPV
        slti  $t1, $t2, 7
        beq   $t1, $zero, dr_sw
        addiu $t2, $t2, 1
        sw    $t2, V_LAPN($zero)        # Tăng biến đếm số Lap đã lưu (tối đa 8)
        j     dr_sw
ds2:    lw    $t4, V_LAPI($zero)
        bne   $t4, $zero, ds_lap_view
        # Đang chạy trực tiếp (LIVE RUNNING): Luôn hiển thị 3 chữ số mili-giây (_MM.SS.mmm) cho cả 9L và 99L
        lw    $a0, REG_SW_VALUE($zero)
        jal   fmtD
        j     dr_out

ds_lap_view:
        # Đang duyệt xem lại mốc Lap $t4 (1..99):
        sll   $t3, $t4, 2
        addiu $t3, $t3, -4
        lw    $a0, V_LAPV($t3)          # Giá trị Lap t4: T_k
        lw    $t0, V_SW_GAP($zero)      # 0: SPLIT, 1: GAP
        beq   $t0, $zero, ds_val_ready
        addiu $t1, $zero, 1
        beq   $t4, $t1, ds_val_ready    # Lap 1: chênh lệch so với mốc 0 là chính T_1
        addiu $t3, $t3, -4
        lw    $t2, V_LAPV($t3)          # T_{k-1}
        subu  $a0, $a0, $t2             # Delta = T_k - T_{k-1}

ds_val_ready:
        lw    $t0, V_SW_MODE($zero)
        bne   $t0, $zero, dr_sw_99      # Nếu V_SW_MODE == 1: 99 Laps (LL MM.SS.cc)

        # ---------------- 9 LAPS @ 1 MS (L MM.SS.mmm) ----------------
        jal   fmtD
        sw    $t4, D7($zero)            # DISP7 hiển thị số thứ tự Lap (1..9)
        lw    $t0, V_SW_GAP($zero)
        beq   $t0, $zero, dr_out        # SPLIT mode: Giữ nguyên số 0 đầu
        addiu $a1, $zero, D4
        j     sw_blank_lead

dr_sw_99:
        # ---------------- 99 LAPS @ 10 MS (LL MM.SS.cc) ----------------
        ori   $t1, $zero, 1000
        div   $a0, $t1
        mflo  $t0                       # t0 = tổng số giây
        mfhi  $t2                       # t2 = ms dư (0..999)
        addiu $t1, $zero, 10
        div   $t2, $t1
        mflo  $t2                       # t2 = centisecond cc (0..99)
        div   $t2, $t1
        mflo  $t5                       # t5 = hàng chục cc
        sw    $t5, D1($zero)
        mfhi  $t5                       # t5 = hàng đơn vị cc
        sw    $t5, D0($zero)

        addiu $t1, $zero, 60
        div   $t0, $t1
        mflo  $t3                       # t3 = tổng số phút
        mfhi  $t4                       # t4 = số giây (0..59)
        addiu $t1, $zero, 10
        div   $t4, $t1
        mflo  $t5                       # Hàng chục giây
        sw    $t5, D3($zero)
        mfhi  $t5                       # Hàng đơn vị giây
        ori   $t5, $t5, CHAR_DP         # Dấu chấm sau Giây tại D2
        sw    $t5, D2($zero)

        div   $t3, $t1
        mflo  $t5                       # Hàng chục phút
        sw    $t5, D5($zero)
        mfhi  $t5                       # Hàng đơn vị phút
        ori   $t5, $t5, CHAR_DP         # Dấu chấm sau Phút tại D4
        sw    $t5, D4($zero)

        # D7..D6 = Số thứ tự Lap ID (01..99)
        lw    $t4, V_LAPI($zero)
        div   $t4, $t1
        mflo  $t5                       # Hàng chục Lap ID
        sw    $t5, D7($zero)
        mfhi  $t5                       # Hàng đơn vị Lap ID
        sw    $t5, D6($zero)

        lw    $t0, V_SW_GAP($zero)
        beq   $t0, $zero, dr_out        # SPLIT mode: Giữ nguyên số 0 đầu
        addiu $a1, $zero, D3

sw_blank_lead:
        # Tắt các số 0 ở đầu (Leading Zero Blanking): D+8, D+4, D+0
        lw    $t1, 8($a1)
        bne   $t1, $zero, dr_out
        addiu $t5, $zero, CHAR_BLANK
        sw    $t5, 8($a1)
        lw    $t1, 4($a1)
        andi  $t2, $t1, 0x7f
        bne   $t2, $zero, dr_out
        sw    $t5, 4($a1)
        lw    $t1, 0($a1)
        bne   $t1, $zero, dr_out
        sw    $t5, 0($a1)
        j     dr_out
