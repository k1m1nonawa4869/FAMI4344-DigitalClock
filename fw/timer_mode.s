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

        # --------------------------------------------------------------------
        # NÚT A: Bắt đầu / Tiếp tục chạy (Start / Resume)
        # Nếu đang chạy: Giữ nguyên (không dừng, bấm nhiều lần không đảo trạng thái)
        # --------------------------------------------------------------------
        bne   $t2, $zero, tr_ret        # Đang chạy: Bấm A không tắt đồng hồ
        lw    $t3, V_TPAUSED($zero)
        bne   $t3, $zero, tr_a_run      # Nếu vừa tạm dừng: Resume lại, giữ snapshot ban đầu
        # Bắt đầu mới: Lưu giá trị hiện tại vào snapshot để reset B khôi phục
        lw    $t4, REG_TMR_VALUE($zero)
        sw    $t4, V_TMR_SNAP($zero)
tr_a_run:
        sw    $zero, V_TPAUSED($zero)   # Xóa cờ tạm dừng
        andi  $t0, $t0, 0xc             # Giữ nguyên cờ BEEP_EN và SAT
        ori   $t0, $t0, TMR_BIT_EN      # RUN = 1
        sw    $t0, REG_TMR_CTRL($zero)
        jr    $ra

        # --------------------------------------------------------------------
        # NÚT B: 
        # - Đang chạy: Reset về mốc trước khi bấm A (V_TMR_SNAP), dừng bộ đếm
        # - Đang dừng: Đặt lại về toàn số 0 (Reset full 0s)
        # --------------------------------------------------------------------
tr_b:   addiu $t1, $zero, 2
        bne   $a0, $t1, tr_c
        sw    $zero, V_TPAUSED($zero)   # Xóa cờ tạm dừng
        bne   $t2, $zero, tr_b_running  # Đang chạy: Khôi phục mốc trước khi bấm A

        # Đang dừng (NOT RUNNING): Đặt lại về toàn số 0 (Full 0s)
        sw    $zero, REG_TMR_VALUE($zero)
        addiu $t0, $zero, 6             # CLR = 1, BEEP_EN = 1, RUN = 0
        sw    $t0, REG_TMR_CTRL($zero)
        sw    $zero, V_TMR_SNAP($zero)
        jr    $ra

tr_b_running:
        # Đang chạy (RUNNING): Khôi phục mốc trước khi bấm A, dừng và xóa cờ ZERO
        lw    $t4, V_TMR_SNAP($zero)
        sw    $t4, REG_TMR_VALUE($zero)
        addiu $t0, $zero, 6             # CLR = 1, BEEP_EN = 1, RUN = 0
        sw    $t0, REG_TMR_CTRL($zero)
        jr    $ra

        # --------------------------------------------------------------------
        # NÚT C:
        # - Đang chạy: Tạm dừng đếm lùi (Pause), giữ nguyên giá trị hiện tại
        # - Đang tạm dừng: Bấm C tiếp tục giữ Pause (chống lỡ tay chuyển mode)
        # - Đang dừng/reset tĩnh: Vào chế độ SET cài đặt thời gian đếm lùi
        # --------------------------------------------------------------------
tr_c:   bne   $t2, $zero, tr_c_pause    # Đang chạy: Nút C tạm dừng đồng hồ
        lw    $t3, V_TPAUSED($zero)
        bne   $t3, $zero, tr_ret        # Đang tạm dừng: Bấm C tiếp tục giữ Pause

        # Đang dừng tĩnh (chưa chạy / đã reset 0): Vào SET cài đặt thời gian
        addiu $t0, $zero, 1
        sw    $t0, V_TPAGE($zero)       # Chuyển sang trang Cài đặt Timer trong SET (V_TPAGE = 1)
        addiu $t0, $zero, MODE_SET
        sw    $t0, V_MODE($zero)        # Chuyển FSM sang chế độ SET (4)
        j     set_in                    # Gọi thủ tục khởi tạo SET

tr_c_pause:
        andi  $t0, $t0, 0xc             # Dừng đếm: RUN = 0, giữ cờ BEEP_EN và SAT
        sw    $t0, REG_TMR_CTRL($zero)
        addiu $t3, $zero, 1
        sw    $t3, V_TPAUSED($zero)     # Bật cờ đánh dấu đang tạm dừng (Pause)
tr_ret: jr    $ra

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
