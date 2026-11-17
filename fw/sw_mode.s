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
sw_c:   lw    $t0, V_LAPI($zero)        # Nút C: Duyệt xem lại các vòng Lap (1 -> 2 -> ... -> n -> Trực tiếp)
        lw    $t1, V_LAPN($zero)
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
        beq   $t1, $zero, dr_sw         # Đã đầy 8 Lap trong DMEM: Bỏ qua phần tử dư
        lui   $t1, 0x1fff
        ori   $t1, $t1, 0xffff          # Mặt nạ 29-bit giá trị mili-giây
        and   $t0, $t0, $t1
        sll   $t3, $t2, 2
        sw    $t0, V_LAPV($t3)          # Lưu giá trị Lap vào mảng V_LAPV
        addiu $t2, $t2, 1
        sw    $t2, V_LAPN($zero)        # Tăng biến đếm số Lap đã lưu
        j     dr_sw
ds2:    lw    $t4, V_LAPI($zero)
        lw    $a0, REG_SW_VALUE($zero)  # Mặc định lấy giá trị chạy trực tiếp từ phần cứng
        beq   $t4, $zero, ds3           # Đang ở chế độ xem trực tiếp
        sll   $t3, $t4, 2
        addiu $t3, $t3, -4
        lw    $a0, V_LAPV($t3)          # Lấy giá trị Lap tương ứng từ mảng
ds3:    jal   fmtD                      # Định dạng hiển thị thời gian
        lw    $t4, V_LAPI($zero)
        beq   $t4, $zero, dr_out
        sw    $t4, D7($zero)            # Nếu đang xem Lap: Ô DISP7 hiển thị số thứ tự Lap (1..8)
        j     dr_out
