# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/timer_mode.s — Xử Lý Chế Độ Đếm Lùi & Đồng Hồ Cờ Vua Kép
# VAI TRÒ:        Xử lý sự kiện nút bấm và hiển thị chế độ TIMER:
#                 - Đếm lùi Đơn (Single Timer) với mốc giờ/phút/giây, quá giờ âm.
#                 - Đồng hồ Cờ vua Kép (Chess Double Clock) 4-digit động 0.01s.
#                 - Khóa an toàn chống bấm nhầm Reset 3 lần liên tiếp Phím B.
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Tái Sử Dụng Vi Kiến Trúc (Hardware Architecture Reuse):
#      Môn cờ vua có đặc tính: Tại một thời điểm chỉ có 1 đấu thủ suy nghĩ.
#      Do đó, hệ thống chỉ dùng đúng 1 khối phần cứng countdown_core.v duy nhất:
#      khi đổi lượt, CPU lưu thời gian của bên vừa đánh vào DMEM và nạp thời gian
#      của đối phương vào REG_TMR_VALUE để đếm tiếp.
#    - Định Dạng Động 3 Cấp (3-Tier Dynamic LED Formatting):
#      + Khi >= 1 phút: MM.SS (ví dụ 05.00)
#      + Khi < 1 phút dương: SS.cc (độ phân giải 0.01s = centi-giây)
#      + Khi quá giờ âm: -S.cc (tối đa -9.99s, sau đó bão hòa)
#    - Khóa An Toàn Chống Bấm Nhầm (Triple-Click Safety Reset):
#      Để ngăn chặn người chơi/trọng tài vô ý quệt vào phím Reset (Phím B) làm
#      hỏng ván cờ, lệnh Reset chỉ kích hoạt khi bấm 3 lần liên tiếp (delta <= 600ms).
# ============================================================================

# ----------------------------------------------------------------------------
# 1. XỬ LÝ SỰ KIỆN NÚT BẤM TRONG CHẾ ĐỘ TIMER
# ----------------------------------------------------------------------------
tr_btn: lw    $t0, REG_TMR_CTRL($zero)  # Đọc thanh ghi điều khiển Timer
        andi  $t2, $t0, TMR_BIT_EN       # Trích xuất cờ RUN (bit 0)
        addiu $t1, $zero, 1
        bne   $a0, $t1, tr_b

        # --------------------------------------------------------------------
        # NÚT A:
        # - Single Timer: Bắt đầu / Tiếp tục chạy (Start / Resume)
        # - Chess Clock: Đấu thủ Trái (Left Clock)
        # --------------------------------------------------------------------
        lw    $t6, V_TMR_SUBMODE($zero)
        bne   $t6, $zero, ch_btn_a

        # Single Timer Phím A
        bne   $t2, $zero, tr_ret        # Đang chạy: Bấm A không tắt đồng hồ
        lw    $t3, V_TPAUSED($zero)
        bne   $t3, $zero, tr_a_run      # Nếu vừa tạm dừng: Resume lại, giữ snapshot ban đầu
        lw    $t4, REG_TMR_VALUE($zero)
        sw    $t4, V_TMR_SNAP($zero)
tr_a_run:
        sw    $zero, V_TPAUSED($zero)   # Xóa cờ tạm dừng
        andi  $t0, $t0, 0xc             # Giữ nguyên cờ BEEP_EN và SAT
        ori   $t0, $t0, TMR_BIT_EN      # RUN = 1
        sw    $t0, REG_TMR_CTRL($zero)
        jr    $ra

ch_btn_a:
        # Chess Clock Phím A (Đấu thủ Trái):
        # Nếu Trái đang chạy (ACT == 1): Bấm A tiếp KHÔNG ĐỔI (Switch an toàn)
        lw    $t3, V_CHESS_ACT($zero)
        addiu $t1, $zero, 1
        beq   $t3, $t1, tr_ret          # Đã là Trái: bỏ qua
        addiu $t1, $zero, 2
        bne   $t3, $t1, ch_a_from_idle  # Nếu không phải Phải (tức đang Idle): bắt đầu Trái

        # Đang là Phải chạy (ACT == 2): Lưu Phải, Chuyển sang Trái
        lw    $t4, REG_TMR_VALUE($zero)
        sw    $t4, V_CHESS_R($zero)     # Lưu thời gian hiện tại của Phải
ch_a_from_idle:
        lw    $t4, V_CHESS_L($zero)     # Nạp thời gian của Trái vào phần cứng
        sw    $t4, REG_TMR_VALUE($zero)
        addiu $t3, $zero, 1
        sw    $t3, V_CHESS_ACT($zero)   # ACT = 1 (Trái đang chạy)
        addiu $t0, $zero, 7             # RUN=1, CLR=1, BEEP_EN=1
        sw    $t0, REG_TMR_CTRL($zero)
        jr    $ra

        # --------------------------------------------------------------------
        # NÚT B: Khóa An Toàn Triple-Click Reset (Bấm nhanh 3 lần <= 600 ms)
        # --------------------------------------------------------------------
tr_b:   addiu $t1, $zero, 2
        bne   $a0, $t1, tr_c

        lw    $t0, REG_RTC_MS($zero)    # t_now
        lw    $t1, V_B_LAST($zero)      # t_last
        lw    $t2, V_B_CNT($zero)       # click count
        sw    $t0, V_B_LAST($zero)      # Cập nhật t_last = t_now

        subu  $t3, $t0, $t1             # delta = t_now - t_last
        slt   $t5, $t3, $zero
        beq   $t5, $zero, tb_dt_ok
        lui   $t4, 0x0526
        ori   $t4, $t4, 0x5c00          # 86.400.000 ms bù nửa đêm
        addu  $t3, $t3, $t4
tb_dt_ok:
        ori   $t4, $zero, 600           # Cửa sổ 600 ms
        slt   $t5, $t4, $t3             # t5 = (600 < delta) ? 1 : 0
        bne   $t5, $zero, tb_reset_1    # delta > 600ms: đếm lại từ 1
        beq   $t2, $zero, tb_reset_1    # Chưa bấm lần nào: đặt = 1

        addiu $t2, $t2, 1               # Bấm tiếp trong cửa sổ <= 600 ms
        sw    $t2, V_B_CNT($zero)
        addiu $t4, $zero, 3
        bne   $t2, $t4, tr_ret          # Chưa đủ 3 lần: BỎ QUA (Khóa chống bấm nhầm)

        # ĐÃ BẤM ĐỦ 3 LẦN LIÊN TIẾP: THỰC THI RESET!
        sw    $zero, V_B_CNT($zero)     # Reset bộ đếm lần bấm
        lw    $t6, V_TMR_SUBMODE($zero)
        bne   $t6, $zero, tr_b_chess_rst

        # Reset trong Single Timer:
        sw    $zero, V_TPAUSED($zero)   # Xóa cờ tạm dừng
        lw    $t0, REG_TMR_CTRL($zero)  # Đọc lại trạng thái Timer
        andi  $t2, $t0, TMR_BIT_EN       # Trích xuất cờ RUN (bit 0)
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

tr_b_chess_rst:
        # Reset trong Chess Clock: TÁI ĐẤU (REMATCH)!
        # Khôi phục Trái về s1 (V_CHESS_INIT) và Phải về s2 (V_CHESS_R_INIT)
        lw    $t4, V_CHESS_INIT($zero)
        sw    $t4, V_CHESS_L($zero)
        lw    $t5, V_CHESS_R_INIT($zero)
        sw    $t5, V_CHESS_R($zero)
        sw    $zero, V_CHESS_ACT($zero) # Về trạng thái Chờ (Idle)
        sw    $t4, REG_TMR_VALUE($zero)
        addiu $t0, $zero, 6             # CLR = 1, BEEP_EN = 1, RUN = 0
        sw    $t0, REG_TMR_CTRL($zero)
        jr    $ra

tb_reset_1:
        addiu $t2, $zero, 1
        sw    $t2, V_B_CNT($zero)       # Đặt lần bấm đầu tiên
        jr    $ra                       # Thoát, chưa reset

        # --------------------------------------------------------------------
        # NÚT C:
        # - Single Timer: Tạm dừng / Vào SET
        # - Chess Clock: Đấu thủ Phải (Right Clock)
        # --------------------------------------------------------------------
tr_c:   lw    $t6, V_TMR_SUBMODE($zero)
        bne   $t6, $zero, ch_btn_c

        # Single Timer Phím C:
        bne   $t2, $zero, tr_c_pause    # Đang chạy: Nút C tạm dừng đồng hồ
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
        jr    $ra

ch_btn_c:
        # Chess Clock Phím C (Đấu thủ Phải):
        # Nếu Phải đang chạy (ACT == 2): Bấm C tiếp KHÔNG ĐỔI (Switch an toàn)
        lw    $t3, V_CHESS_ACT($zero)
        addiu $t1, $zero, 2
        beq   $t3, $t1, tr_ret          # Đã là Phải: bỏ qua
        addiu $t1, $zero, 1
        bne   $t3, $t1, ch_c_from_idle  # Nếu không phải Trái (đang Idle): bắt đầu Phải

        # Đang là Trái chạy (ACT == 1): Lưu Trái, Chuyển sang Phải
        lw    $t4, REG_TMR_VALUE($zero)
        sw    $t4, V_CHESS_L($zero)     # Lưu thời gian hiện tại của Trái
ch_c_from_idle:
        lw    $t4, V_CHESS_R($zero)     # Nạp thời gian của Phải vào phần cứng
        sw    $t4, REG_TMR_VALUE($zero)
        addiu $t3, $zero, 2
        sw    $t3, V_CHESS_ACT($zero)   # ACT = 2 (Phải đang chạy)
        addiu $t0, $zero, 7             # RUN=1, CLR=1, BEEP_EN=1
        sw    $t0, REG_TMR_CTRL($zero)
tr_ret: jr    $ra

# ----------------------------------------------------------------------------
# 2. XỬ LÝ VẼ MÀN HÌNH CHẾ ĐỘ TIMER
# ----------------------------------------------------------------------------
dr_tr:  lw    $t6, V_TMR_SUBMODE($zero)
        bne   $t6, $zero, dr_tr_chess

        # --------------------------------------------------------------------
        # SINGLE TIMER DISPLAY
        # --------------------------------------------------------------------
        lw    $a0, REG_TMR_VALUE($zero) # Đọc thời gian đếm lùi phần cứng (số nguyên có dấu 32-bit)
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

        # --------------------------------------------------------------------
        # CHESS DOUBLE CLOCK DISPLAY (8 DIGITS = LEFT S7..S4 + RIGHT S3..S0)
        # --------------------------------------------------------------------
dr_tr_chess:
        # Cập nhật thời gian thực vào biến tương ứng của bên đang chạy
        lw    $t3, V_CHESS_ACT($zero)
        lw    $t4, REG_TMR_VALUE($zero)
        addiu $t1, $zero, 1
        bne   $t3, $t1, dtr_ch_r
        sw    $t4, V_CHESS_L($zero)     # Nếu Trái đang chạy: đồng bộ giá trị phần cứng
        j     dtr_ch_draw
dtr_ch_r:
        addiu $t1, $zero, 2
        bne   $t3, $t1, dtr_ch_draw
        sw    $t4, V_CHESS_R($zero)     # Nếu Phải đang chạy: đồng bộ giá trị phần cứng

dtr_ch_draw:
        addu  $s7, $ra, $zero           # Lưu $ra vào $s7

        # Vẽ Left Clock lên S7..S4 ($a1 = 4)
        lw    $a0, V_CHESS_L($zero)
        addiu $a1, $zero, 4
        jal   fmt_chess_side

        # Vẽ Right Clock lên S3..S0 ($a1 = 0)
        lw    $a0, V_CHESS_R($zero)
        addu  $a1, $zero, $zero
        jal   fmt_chess_side

        addu  $ra, $s7, $zero
        j     dr_out

# ----------------------------------------------------------------------------
# 3. HÀM ĐỊNH DẠNG 4 CHỮ SỐ CHO MỘT BÊN ĐỒNG HỒ CỜ VUA (FMT CHESS SIDE)
#    Đầu vào: $a0 = Thời gian (ms có dấu)
#             $a1 = Vị trí chữ số cơ sở (4 cho Left: S7..S4, 0 cho Right: S3..S0)
# ----------------------------------------------------------------------------
fmt_chess_side:
        # Kiểm tra quá giờ âm: a0 < 0
        slt   $t0, $a0, $zero
        bne   $t0, $zero, fcs_neg

        # Kiểm tra nếu >= 60.000 ms (>= 1 phút): định dạng MM.SS
        ori   $t1, $zero, 60000
        slt   $t0, $a0, $t1             # a0 < 60000 ?
        bne   $t0, $zero, fcs_sub_min   # Nếu < 60.000 ms: định dạng SS.cc

        # ------------------------------------------------------------
        # TRƯỜNG HỢP 1: >= 1 phút -> Định dạng MM.SS
        # ------------------------------------------------------------
        ori   $t1, $zero, 1000
        div   $a0, $t1
        mflo  $t0                       # t0 = tổng số giây
        addiu $t1, $zero, 60
        div   $t0, $t1
        mflo  $t2                       # t2 = Phút (0..59)
        mfhi  $t3                       # t3 = Giây (0..59)

        addiu $t1, $zero, 10
        div   $t2, $t1
        mflo  $t8                       # t8 (d3) = Phút hàng chục
        mfhi  $t9                       # t9 (d2) = Phút hàng đơn vị
        ori   $t9, $t9, CHAR_DP         # Bật dấu chấm ở ô thứ 2

        div   $t3, $t1
        mflo  $t6                       # t6 (d1) = Giây hàng chục
        mfhi  $t7                       # t7 (d0) = Giây hàng đơn vị
        j     fcs_write

fcs_sub_min:
        # ------------------------------------------------------------
        # TRƯỜNG HỢP 2: < 1 phút dương -> Định dạng SS.cc (0.01s precision)
        # ------------------------------------------------------------
        ori   $t1, $zero, 1000
        div   $a0, $t1
        mflo  $t2                       # t2 = Giây (0..59)
        mfhi  $t3                       # t3 = Mili-giây dư (0..999)

        addiu $t1, $zero, 10
        div   $t2, $t1
        mflo  $t8                       # t8 (d3) = Giây hàng chục
        mfhi  $t9                       # t9 (d2) = Giây hàng đơn vị
        ori   $t9, $t9, CHAR_DP         # Bật dấu chấm ở ô thứ 2

        div   $t3, $t1
        mflo  $t4                       # t4 = Centi-giây (0..99)
        div   $t4, $t1
        mflo  $t6                       # t6 (d1) = Centi hàng chục
        mfhi  $t7                       # t7 (d0) = Centi hàng đơn vị
        j     fcs_write

fcs_neg:
        # ------------------------------------------------------------
        # TRƯỜNG HỢP 3: Quá giờ âm -> Định dạng -S.cc (Tối đa -9.99s)
        # ------------------------------------------------------------
        subu  $t0, $zero, $a0           # |a0| = 0 - a0
        ori   $t1, $zero, 9990          # Giới hạn cực đại 9.99s = 9990 ms
        slt   $t2, $t1, $t0
        beq   $t2, $zero, fcs_neg_clamp
        addu  $t0, $zero, $t1           # Bão hòa tại 9990 ms (-9.99)
fcs_neg_clamp:
        ori   $t1, $zero, 1000
        div   $t0, $t1
        mflo  $t2                       # t2 = Giây đơn vị (0..9)
        mfhi  $t3                       # t3 = ms dư (0..999)

        addiu $t8, $zero, CHAR_DASH     # t8 (d3) = '-'
        addu  $t9, $t2, $zero
        ori   $t9, $t9, CHAR_DP         # t9 (d2) = Giây + Dấu chấm

        addiu $t1, $zero, 10
        div   $t3, $t1
        mflo  $t4                       # t4 = Centi-giây (0..99)
        div   $t4, $t1
        mflo  $t6                       # t6 (d1) = Centi hàng chục
        mfhi  $t7                       # t7 (d0) = Centi hàng đơn vị

fcs_write:
        # Ghi các chữ số vào mảng D0..D7:
        # a1 = 4 -> D7(t8), D6(t9), D5(t6), D4(t7)
        # a1 = 0 -> D3(t8), D2(t9), D1(t6), D0(t7)
        sll   $v0, $a1, 2               # a1 * 4
        addiu $v0, $v0, D0              # Địa chỉ D0 + a1*4
        sw    $t7, 0($v0)               # D4 hoặc D0
        sw    $t6, 4($v0)               # D5 hoặc D1
        sw    $t9, 8($v0)               # D6 hoặc D2
        sw    $t8, 12($v0)              # D7 hoặc D3
        jr    $ra
