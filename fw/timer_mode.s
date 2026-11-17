# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/timer_mode.s — Xử Lý Chế Độ Đếm Lùi Thời Gian (TIMER Mode)
# VAI TRÒ:        Xử lý sự kiện nút bấm và hiển thị chế độ TIMER: Cài đặt thời
#                 gian đếm lùi, kích hoạt chạy/dừng, đếm quá giờ âm 32-bit
#                 và phát cảnh báo chuông còi khi hết giờ.
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Đếm Quá Giờ Bù Hai (Two's Complement Negative Overtime Counting):
#      Khi bộ đếm giảm về 0, phần cứng phát cờ ZERO và tiếp tục đếm xuống
#      các giá trị âm (-1, -2, ...). Điều này giúp người dùng biết chính xác
#      sự kiện đã kết thúc quá hạn bao nhiêu lâu.
#    - Định Dạng Hiển Thị Số Âm:
#      Khi giá trị âm, phần mềm trích xuất trị tuyệt đối của số mili-giây
#      để hiển thị lên các ô LED, đồng thời bật ký tự dấu gạch ngang '-'
#      tại ô ngoài cùng bên trái (DISP7).
# ============================================================================

# ----------------------------------------------------------------------------
# 1. XỬ LÝ SỰ KIỆN NÚT BẤM TRONG CHẾ ĐỘ TIMER
# ----------------------------------------------------------------------------
tr_btn: lw    $t0, REG_TMR_CTRL($zero)  # Đọc thanh ghi điều khiển Timer
        andi  $t2, $t0, TMR_BIT_EN       # Trích xuất cờ RUN (bit 0)
        addiu $t1, $zero, 1
        bne   $a0, $t1, tr_b
        andi  $t0, $t0, 0xc             # Nút A: Đảo cờ RUN, giữ nguyên BEEP_EN và SAT
        bne   $t2, $zero, tr_a1         # Đang chạy: Dừng lại (RUN = 0)
        ori   $t0, $t0, TMR_BIT_EN      # Đang dừng: Bật chạy (RUN = 1)
tr_a1:  sw    $t0, REG_TMR_CTRL($zero)
        jr    $ra
tr_b:   addiu $t1, $zero, 2
        bne   $a0, $t1, tr_c
tr_rst: lw    $t0, V_PRE($zero)         # Nút B: Khôi phục về giá trị đặt trước, dừng và xóa cờ ZERO
        sw    $t0, REG_TMR_VALUE($zero)
        addiu $t0, $zero, 6             # CLR = 1, BEEP_EN = 1
        sw    $t0, REG_TMR_CTRL($zero)
        jr    $ra
tr_c:   bne   $t2, $zero, tr_r          # Nút C: Chỉ có tác dụng khi Timer đang dừng
        lw    $t0, V_PRE($zero)
        ori   $t1, $zero, 60000         # Mỗi lần nhấn tăng thêm 1 phút (+60.000 ms)
        addu  $t0, $t0, $t1
        lui   $t1, 0x36
        ori   $t1, $t1, 0xee80          # 3.600.000 ms = 60 phút
        slt   $t2, $t0, $t1
        bne   $t2, $zero, tr_c1         # Nếu vượt quá 60 phút thì quay vòng về 0
        subu  $t0, $t0, $t1
tr_c1:  sw    $t0, V_PRE($zero)         # Cập nhật giá trị đặt mới
        j     tr_rst                    # Tự động nạp giá trị mới vào thanh ghi phần cứng
tr_r:   jr    $ra

# ----------------------------------------------------------------------------
# 2. XỬ LÝ VẼ MÀN HÌNH CHẾ ĐỘ TIMER
# ----------------------------------------------------------------------------
dr_tr:  lw    $a0, REG_TMR_VALUE($zero) # Đọc thời gian đếm lùi phần cứng (số nguyên có dấu 32-bit)
        addiu $t7, $zero, CHAR_BLANK    # Mặc định ô DISP7 là khoảng trắng (khi số dương)
        lui   $t1, 0xea8a
        ori   $t1, $t1, 0xd601          # Giới hạn âm cực đại: -359.999.999 ms (-99:59:59.999)
        slt   $t0, $a0, $t1             # Kiểm tra tràn bão hòa âm
        beq   $t0, $zero, dtr1
        addiu $t7, $zero, CHAR_DASH     # Bật dấu '-'
        lui   $a0, 0x1575
        ori   $a0, $a0, 0x2a00          # Ép giá trị sang định dạng vạch ngang "--.--.--"
        j     dtr2
dtr1:   slt   $t0, $a0, $zero           # Kiểm tra số âm quá giờ
        beq   $t0, $zero, dtr2
        addiu $t7, $zero, CHAR_DASH     # Hiển thị dấu '-' ở ô DISP7
        subu  $a0, $zero, $a0           # Lấy trị tuyệt đối: |a0| = 0 - a0
dtr2:   jal   fmtD                      # Định dạng số mili-giây
        sw    $t7, D7($zero)            # Ghi dấu âm hoặc khoảng trắng vào ô DISP7
        j     dr_out
