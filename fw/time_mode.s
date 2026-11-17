# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/time_mode.s — Xử Lý Chế Độ Đồng Hồ Thời Gian Thực (TIME Mode)
# VAI TRÒ:        Xử lý sự kiện nút bấm và hiển thị chế độ TIME: Chuyển đổi 12/24h,
#                 xoay vòng trang hiển thị (Giờ -> Giây.ms -> Ngày.tháng),
#                 điều chỉnh độ sáng màn hình LED 7 đoạn (15 -> 9 -> 3).
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Định Dạng Hiển Thị Đồng Hồ Kép (12h AM/PM vs 24h Military Format):
#      Ở chế độ 12h, ký tự ngoài cùng bên trái (DISP7) hiển thị chữ 'A' (AM)
#      hoặc 'P' (PM). Giờ 00:00 quy đổi thành 12:00 AM; giờ 13:00..23:59 trừ 12.
#    - Đọc Nguyên Tử Đồng Hồ Thời Gian Thực (Atomic RTC Reading):
#      Khi đọc MS_OF_DAY, phần cứng tự động chốt giá trị ngày và thứ vào
#      thanh ghi bóng DAY_SHADOW. Khóa ngắt tạm thời trong lúc đọc liên tiếp
#      2 thanh ghi này để ngăn trình ngắt UART can thiệp làm thay đổi chốt bóng.
# ============================================================================

# ----------------------------------------------------------------------------
# 1. XỬ LÝ SỰ KIỆN NÚT BẤM TRONG CHẾ ĐỘ TIME
# ----------------------------------------------------------------------------
tm_btn: addiu $t1, $zero, 1
        bne   $a0, $t1, tm_b
        lw    $t0, V_H12($zero)         # Nút A: Đảo định dạng 12h / 24h
        subu  $t0, $t1, $t0
        sw    $t0, V_H12($zero)
        jr    $ra
tm_b:   addiu $t1, $zero, 2
        bne   $a0, $t1, tm_c
        lw    $t0, V_TV($zero)          # Nút B: Xoay vòng hiển thị (Giờ -> Giây.ms -> Ngày)
        addiu $t0, $t0, 1
        addiu $t1, $zero, 3
        bne   $t0, $t1, tm_b1
        addu  $t0, $zero, $zero
tm_b1:  sw    $t0, V_TV($zero)
        jr    $ra
tm_c:   lw    $t0, V_BRI($zero)         # Nút C: Giảm độ sáng LED (15 -> 9 -> 3 -> 15)
        addiu $t0, $t0, -6
        slti  $t1, $t0, 1
        beq   $t1, $zero, tm_c1
        addiu $t0, $zero, 15
tm_c1:  sw    $t0, V_BRI($zero)
        sw    $t0, REG_BRIGHT($zero)    # Ghi vào thanh ghi độ sáng phần cứng
        jr    $ra

# ----------------------------------------------------------------------------
# 2. XỬ LÝ VẼ MÀN HÌNH CHẾ ĐỘ TIME
# ----------------------------------------------------------------------------
dr_tm:  mtc0  $zero, $12                # Tắt ngắt tạm thời để đọc nguyên tử cặp MS và DAY
        lw    $a0, REG_RTC_MS($zero)    # Đọc mili-giây trong ngày (phần cứng chốt DAY_SHADOW)
        lw    $t4, REG_DAY_SHADOW($zero) # Đọc ngày chốt cùng khoảnh khắc
        addiu $t0, $zero, USE_IRQ
        mtc0  $t0, $12                  # Khôi phục trạng thái ngắt
        lw    $t0, V_TV($zero)
        addiu $t1, $zero, 1
        beq   $t0, $t1, dt_ms           # Trang 1: Giây và mili-giây
        addiu $t1, $zero, 2
        beq   $t0, $t1, dt_dy           # Trang 2: Ngày, tháng, năm
        lw    $a1, V_H12($zero)         # Trang 0: Giờ:Phút:Giây (12/24h)
        jal   fmtB
        j     dr_out
dt_ms:  lui   $t1, 0x36
        ori   $t1, $t1, 0xee80          # 3.600.000 ms = 1 giờ
        div   $a0, $t1
        mfhi  $a0                       # Lấy phần dư dưới 1 giờ (phút:giây.ms)
        jal   fmtA
        j     dr_out
dt_dy:  andi  $a0, $t4, 0xffff          # Trích xuất 16-bit số ngày từ mốc quy chuẩn
        jal   d2ymd                     # Chuyển đổi sang Năm, Tháng, Ngày
dt_dd:  slti  $t1, $a1, 100             # Giới hạn hiển thị 2 chữ số năm (2000..2099)
        bne   $t1, $zero, dt_d1
        addiu $a1, $a1, -100
dt_d1:  lui   $t1, 0xf
        ori   $t1, $t1, 0x4240          # 1.000.000
        mul   $t5, $t5, $t1
        ori   $t1, $zero, 1000
        mul   $t0, $a0, $t1
        addu  $t5, $t5, $t0
        addu  $a0, $t5, $a1             # Định dạng số ghép: Ngày (2 chữ số) | Tháng | Năm
        addiu $a1, $zero, 8
        jal   putd
        addiu $t0, $zero, CHAR_DASH
        sw    $t0, D2($zero)            # Chèn dấu gạch nối giữa Tháng và Năm
        sw    $t0, D5($zero)            # Chèn dấu gạch nối giữa Ngày và Tháng
        j     dr_out
