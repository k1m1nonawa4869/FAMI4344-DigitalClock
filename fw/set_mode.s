# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/set_mode.s — Xử Lý Chế Độ Cài Đặt Giờ Thủ Công (SET Mode)
# VAI TRÒ:        Máy trạng thái chỉnh giờ nhấp nháy 2 Hz cho 6 trường:
#                 Giờ, Phút, Giây, Ngày, Tháng, Năm (2000..2099); thuật toán
#                 tính số ngày trong tháng, năm nhuận và chuyển đổi qua lại
#                 với số ngày tích lũy từ mốc 01/01/2000.
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Máy Trạng Thái Hữu Hạn Điều Khiển Con Người (User Interface FSM):
#      FSM duyệt tuần tự qua 6 trường chỉnh sửa:
#        0: Giờ (0..23) -> 1: Phút (0..59) -> 2: Giây (A ép về 00) ->
#        3: Ngày (1..mlen) -> 4: Tháng (1..12) -> 5: Năm (0..99)
#      Mỗi trường có mặt nạ nhấp nháy REG_BLINK_MASK tương ứng.
#    - Thuật Toán Lịch & Năm Nhuận (Calendar & Leap Year Algorithm):
#      + Tháng 2 có 29 ngày nếu năm chia hết cho 4 (chu kỳ 4 năm = 1461 ngày).
#      + Các tháng 30/31 ngày tính theo công thức: 30 + ((tháng + tháng/8) mod 2).
#      + Khi đổi tháng hoặc năm, tự động kẹp (clamp) ngày về giới hạn cực đại
#        của tháng đó (ví dụ: đang ở 31/01 chuyển sang tháng 02 sẽ kẹp về 28 hoặc 29).
# ============================================================================

# ----------------------------------------------------------------------------
# 1. KHỞI TẠO VÀO CHẾ ĐỘ SET (CAPTURE CURRENT TIME TO SET BUFFERS)
# ----------------------------------------------------------------------------
set_in: addu  $s7, $ra, $zero           # Lưu thanh ghi $ra vào $s7
        lw    $t0, V_TPAGE($zero)       # Kiểm tra trang cài đặt (0: RTC, 1: Timer Preset)
        bne   $t0, $zero, st_in_tmr     # Nếu V_TPAGE == 1: Khởi tạo trang Timer
        mtc0  $zero, $12                # Tắt ngắt để đọc nguyên tử cặp MS và DAY
        lw    $t0, REG_RTC_MS($zero)
        lw    $a0, REG_DAY_SHADOW($zero)
        addiu $t1, $zero, USE_IRQ
        mtc0  $t1, $12                  # Khôi phục ngắt
        ori   $t1, $zero, 1000
        div   $t0, $t1
        mflo  $t0                       # Đổi sang tổng số giây trong ngày
        addiu $t1, $zero, 3600
        div   $t0, $t1
        mflo  $t2
        sw    $t2, V_SH($zero)          # Giờ hiện tại
        mfhi  $t0
        addiu $t1, $zero, 60
        div   $t0, $t1
        mflo  $t2
        sw    $t2, V_SM($zero)          # Phút hiện tại
        mfhi  $t2
        sw    $t2, V_SS($zero)          # Giây hiện tại
        andi  $a0, $a0, 0xffff
        jal   d2ymd                     # Chuyển đổi số ngày sang Năm, Tháng, Ngày
        sw    $t5, V_SD($zero)          # Ngày hiện tại
        sw    $a0, V_SMO($zero)         # Tháng hiện tại
        slti  $t1, $a1, 100             # Giới hạn năm 2000..2099
        bne   $t1, $zero, set_y
        addiu $a1, $a1, -100
set_y:  sw    $a1, V_SY($zero)          # Năm hiện tại (độ lệch từ 2000)
        addu  $t4, $zero, $zero         # Bắt đầu từ trường 0 (Giờ)
        j     st_f

st_in_tmr:
        lw    $t0, V_TMR_SUBMODE($zero) # Đọc chế độ Timer hiện tại (0: Single, 1: Chess)
        sw    $t0, V_TP_SUB($zero)      # Lưu vào biến tạm cấu hình
        lw    $t0, V_PRE($zero)         # Đọc giá trị preset Timer hiện tại (ms)
        lui   $t1, 0x36
        ori   $t1, $t1, 0xee80          # 3.600.000 ms = 1 giờ
        div   $t0, $t1
        mflo  $t2                       # Giờ = V_PRE / 3.600.000
        sw    $t2, V_TPH($zero)
        mfhi  $t0                       # Số ms dư trong giờ
        ori   $t1, $zero, 60000
        div   $t0, $t1
        mflo  $t2                       # Phút = (V_PRE % 3.600.000) / 60.000
        sw    $t2, V_TPM($zero)
        mfhi  $t0                       # Số ms dư trong phút
        ori   $t1, $zero, 1000
        div   $t0, $t1
        mflo  $t2                       # Giây = (V_PRE % 60.000) / 1.000
        sw    $t2, V_TPS($zero)
        addu  $t4, $zero, $zero         # Bắt đầu từ trường 0 (Giờ)
        sw    $t4, V_SF($zero)
        addiu $t0, $zero, 0x30          # Mặt nạ nhấp nháy 2 Hz: DISP5, DISP4 (Giờ)
        sw    $t0, REG_BLINK_MASK($zero)
        jr    $s7

# ----------------------------------------------------------------------------
# 2. XỬ LÝ SỰ KIỆN NÚT BẤM TRONG CHẾ ĐỘ SET
# ----------------------------------------------------------------------------
st_btn: addu  $s7, $ra, $zero
        lw    $t0, V_TPAGE($zero)
        bne   $t0, $zero, st_btn_tmr    # Xử lý phím khi đang ở trang SET Timer
        lw    $t4, V_SF($zero)          # Trường hiện đang chỉnh sửa (0..5)
        addiu $t1, $zero, 2
        beq   $a0, $t1, st_b            # Nút B: Đổi trường tiếp theo
        addiu $t1, $zero, 3
        beq   $a0, $t1, st_sv           # Nút C: Lưu và thoát về chế độ TIME
        sll   $t6, $t4, 2               # Nút A: Tăng giá trị của trường t4
        lw    $t0, V_SH($t6)
        addiu $t0, $t0, 1
        addiu $t1, $zero, 2
        bne   $t4, $t1, st_a1
        addu  $t0, $zero, $zero         # Riêng trường Giây: Nhấn A ép về 00
st_a1:  addiu $t2, $zero, 24            # Ngưỡng vượt cực đại của Giờ (24)
        addu  $t3, $zero, $zero         # Giá trị quay về sau khi vượt
        beq   $t4, $zero, st_w
        addiu $t2, $zero, 60            # Ngưỡng vượt cho Phút và Giây (60)
        slti  $t1, $t4, 3
        bne   $t1, $zero, st_w
        addiu $t3, $zero, 1             # Tháng bắt đầu từ 1
        addiu $t2, $zero, 13            # Ngưỡng vượt cho Tháng (13)
        addiu $t1, $zero, 4
        beq   $t4, $t1, st_w
        addiu $t2, $zero, 100           # Ngưỡng vượt cho Năm (100)
        addu  $t3, $zero, $zero
        addiu $t1, $zero, 5
        beq   $t4, $t1, st_w
        lw    $a0, V_SMO($zero)         # Trường Ngày: Ngưỡng vượt = Số ngày của tháng đó + 1
        lw    $a1, V_SY($zero)
        jal   mlen
        addiu $t2, $v0, 1
        addiu $t3, $zero, 1
st_w:   bne   $t0, $t2, st_w1
        addu  $t0, $t3, $zero
st_w1:  sw    $t0, V_SH($t6)            # Cập nhật giá trị trường mới
        lw    $a0, V_SMO($zero)         # Tự động kẹp Ngày theo Tháng và Năm vừa đổi
        lw    $a1, V_SY($zero)
        jal   mlen
        lw    $t0, V_SD($zero)
        slt   $t1, $v0, $t0
        beq   $t1, $zero, st_r
        sw    $v0, V_SD($zero)          # Kẹp ngày về giá trị cực đại hợp lệ
st_r:   jr    $s7
st_b:   addiu $t4, $t4, 1               # Nút B: Xoay vòng trường (Giờ -> Phút -> Giây -> Ngày -> Tháng -> Năm)
        addiu $t1, $zero, 6
        bne   $t4, $t1, st_f
        addu  $t4, $zero, $zero
st_f:   sw    $t4, V_SF($zero)
        addiu $t0, $zero, 0x30          # Mặt nạ nháy cho Giờ: DISP5, DISP4 (0x30)
        beq   $t4, $zero, st_m
        addiu $t0, $zero, 0x0c          # Mặt nạ nháy cho Phút: DISP3, DISP2 (0x0C)
        addiu $t1, $zero, 1
        beq   $t4, $t1, st_m
        addiu $t0, $zero, 0xc0          # Mặt nạ nháy cho Ngày: DISP7, DISP6 (0xC0)
        addiu $t1, $zero, 3
        beq   $t4, $t1, st_m
        addiu $t0, $zero, 0x18          # Mặt nạ nháy cho Tháng: DISP4, DISP3 (0x18)
        addiu $t1, $zero, 4
        beq   $t4, $t1, st_m
        addiu $t0, $zero, 0x03          # Mặt nạ nháy cho Giây và Năm: DISP1, DISP0 (0x03)
st_m:   sw    $t0, REG_BLINK_MASK($zero) # Nạp mặt nạ nhấp nháy vào phần cứng
        jr    $s7
st_sv:  jal   ymd2d                     # Nút C: Tính tổng số ngày từ 01/01/2000
        addu  $a1, $v0, $zero
        lw    $t0, V_SH($zero)
        addiu $t1, $zero, 60
        mul   $t0, $t0, $t1
        lw    $t2, V_SM($zero)
        addu  $t0, $t0, $t2
        mul   $t0, $t0, $t1
        lw    $t2, V_SS($zero)
        addu  $t0, $t0, $t2
        ori   $t1, $zero, 1000
        mul   $a0, $t0, $t1             # Quy đổi toàn bộ Giờ:Phút:Giây sang mili-giây
        jal   rtcset                    # Nạp giờ và ngày mới vào phần cứng RTC
        sw    $zero, V_T1OK($zero)      # Đặt giờ thủ công: Hủy mốc đồng bộ trước đó để tránh lệch CAL
        sw    $zero, V_MODE($zero)      # Trở về chế độ TIME
        sw    $zero, REG_BLINK_MASK($zero) # Tắt nhấp nháy LED
        jr    $s7

st_btn_tmr:
        lw    $t4, V_SF($zero)          # 0: Giờ, 1: Phút, 2: Giây, 3: Chế độ t1/t2
        addiu $t1, $zero, 2
        beq   $a0, $t1, st_tm_b         # Nút B: Đổi trường (0 -> 1 -> 2 -> 3 -> 0)
        addiu $t1, $zero, 3
        beq   $a0, $t1, st_tm_sv        # Nút C: Lưu preset và thoát về TIMER

        # Nút A: Tăng giá trị (+1) trường đang chọn
        bne   $t4, $zero, st_tm_a_m
        lw    $t0, V_TPH($zero)         # Tăng Giờ (0..99)
        addiu $t0, $t0, 1
        addiu $t1, $zero, 100
        bne   $t0, $t1, st_tm_a_h1
        addu  $t0, $zero, $zero
st_tm_a_h1:
        sw    $t0, V_TPH($zero)
        jr    $s7

st_tm_a_m:
        addiu $t1, $zero, 1
        bne   $t4, $t1, st_tm_a_s
        lw    $t0, V_TPM($zero)         # Tăng Phút (0..59)
        addiu $t0, $t0, 1
        addiu $t1, $zero, 60
        bne   $t0, $t1, st_tm_a_m1
        addu  $t0, $zero, $zero
st_tm_a_m1:
        sw    $t0, V_TPM($zero)
        jr    $s7

st_tm_a_s:
        addiu $t1, $zero, 2
        bne   $t4, $t1, st_tm_a_sub
        lw    $t0, V_TPS($zero)         # Tăng Giây (0..59)
        addiu $t0, $t0, 1
        addiu $t1, $zero, 60
        bne   $t0, $t1, st_tm_a_s1
        addu  $t0, $zero, $zero
st_tm_a_s1:
        sw    $t0, V_TPS($zero)
        jr    $s7

st_tm_a_sub:
        # Trường 3: Đảo chế độ Timer (0: Single t1 <-> 1: Chess t2)
        lw    $t0, V_TP_SUB($zero)
        addiu $t2, $zero, 1
        subu  $t0, $t2, $t0              # 1 - t0: đảo 0 <-> 1 an toàn
        sw    $t0, V_TP_SUB($zero)
        jr    $s7

st_tm_b: # Nút B: Đổi trường xoay vòng (0 -> 1 -> 2 -> 3 -> 0)
        addiu $t4, $t4, 1
        addiu $t1, $zero, 4
        bne   $t4, $t1, st_tm_b0
        addu  $t4, $zero, $zero
st_tm_b0:
        sw    $t4, V_SF($zero)
        addiu $t0, $zero, 0x30          # 0: Nháy Giờ (DISP5, DISP4 = 0x30)
        beq   $t4, $zero, st_tm_b_mask
        addiu $t0, $zero, 0x0c          # 1: Nháy Phút (DISP3, DISP2 = 0x0C)
        addiu $t1, $zero, 1
        beq   $t4, $t1, st_tm_b_mask
        addiu $t0, $zero, 0x03          # 2: Nháy Giây (DISP1, DISP0 = 0x03)
        addiu $t1, $zero, 2
        beq   $t4, $t1, st_tm_b_mask
        addiu $t0, $zero, 0xc0          # 3: Nháy Chế độ (DISP7, DISP6 = 0xC0)
st_tm_b_mask:
        sw    $t0, REG_BLINK_MASK($zero)
        jr    $s7

st_tm_sv: # Nút C: Lưu cấu hình và thoát
        lw    $t5, V_TP_SUB($zero)
        sw    $t5, V_TMR_SUBMODE($zero) # Cập nhật Chế độ Timer chính

        # Tính toán preset mili-giây: ((Giờ * 60 + Phút) * 60 + Giây) * 1000
        lw    $t0, V_TPH($zero)
        addiu $t1, $zero, 60
        mul   $t0, $t0, $t1
        lw    $t2, V_TPM($zero)
        addu  $t0, $t0, $t2
        mul   $t0, $t0, $t1
        lw    $t2, V_TPS($zero)
        addu  $t0, $t0, $t2
        ori   $t1, $zero, 1000
        mul   $t0, $t0, $t1             # $t0 = preset ms

        bne   $t5, $zero, st_tm_sv_chess # Nếu là Chess Clock (t2)

        # Lưu cho Single Timer:
        sw    $t0, V_PRE($zero)
        sw    $t0, REG_TMR_VALUE($zero)
        sw    $t0, V_TMR_SNAP($zero)
        sw    $zero, V_TPAUSED($zero)
        addiu $t2, $zero, 6             # CLR=1, BEEP_EN=1, RUN=0
        sw    $t2, REG_TMR_CTRL($zero)
        j     st_tm_sv_done

st_tm_sv_chess:
        # Lưu cho Chess Clock: Cả Trái và Phải xuất phát cùng preset
        sw    $t0, V_CHESS_INIT($zero)
        sw    $t0, V_CHESS_L($zero)
        sw    $t0, V_CHESS_R($zero)
        sw    $zero, V_CHESS_ACT($zero) # Trạng thái cờ vua về Dừng/Chờ
        sw    $t0, REG_TMR_VALUE($zero)
        addiu $t2, $zero, 6             # CLR=1, BEEP_EN=1, RUN=0
        sw    $t2, REG_TMR_CTRL($zero)

st_tm_sv_done:
        sw    $zero, REG_BLINK_MASK($zero)
        sw    $zero, V_TPAGE($zero)
        addiu $t0, $zero, MODE_TIMER
        sw    $t0, V_MODE($zero)
        jr    $s7

# ----------------------------------------------------------------------------
# 3. HÀM NẠP GIỜ AN TOÀN VÀO PHẦN CỨNG RTC (RTC SET ROUTINE)
# ----------------------------------------------------------------------------
# Đầu vào: $a0 = mili-giây trong ngày, $a1 = số ngày từ 01/01/2000
rtcset: sw    $a0, REG_SET_MS($zero)    # Nạp ms chờ
        addiu $t0, $a1, 6               # 01/01/2000 là Thứ 7 (mã 6)
        addiu $t1, $zero, 7
        div   $t0, $t1
        mfhi  $t0                       # Thứ trong tuần = (ngày + 6) % 7
        sll   $t0, $t0, 16
        or    $t0, $t0, $a1
        sw    $t0, REG_SET_DAY($zero)   # Nạp {dow[2:0], day[15:0]}
        addiu $t0, $zero, RTC_BIT_ARM
        sw    $t0, REG_RTC_CTRL($zero)  # Kích hoạt ARM
rs_arm: lw    $t0, REG_RTC_CTRL($zero)
        bne   $t0, $zero, rs_arm        # Chờ phần cứng hoàn tất chốt nạp
        addiu $t0, $zero, -1
        sw    $t0, V_LASTH($zero)       # Đặt lại LASTH = -1 để tránh chuông giờ giả
        jr    $ra

# ----------------------------------------------------------------------------
# 4. HÀM TÍNH SỐ NGÀY TRONG THÁNG (MONTH LENGTH CALCULATION)
# ----------------------------------------------------------------------------
# Đầu vào: $a0 = Tháng (1..12), $a1 = Năm - 2000 (0..99)
# Đầu ra:  $v0 = Số ngày của tháng đó (28, 29, 30 hoặc 31)
mlen:   addiu $t8, $zero, 2
        bne   $a0, $t8, ml_n            # Không phải tháng 2
        andi  $t8, $a1, 3               # Năm nhuận: Năm chia hết cho 4 (2 bit thấp = 0)
        addiu $v0, $zero, 29
        beq   $t8, $zero, ml_r
        addiu $v0, $zero, 28
ml_r:   jr    $ra
ml_n:   sra   $t8, $a0, 3
        addu  $t8, $t8, $a0
        andi  $t8, $t8, 1
        addiu $v0, $t8, 30             # 30 + ((tháng + tháng/8) mod 2)
        jr    $ra

# ----------------------------------------------------------------------------
# 5. HÀM CHUYỂN ĐỔI NGÀY SANG NĂM - THÁNG - NGÀY (DAYS TO Y-M-D)
# ----------------------------------------------------------------------------
# Đầu vào: $a0 = Số ngày từ 01/01/2000
# Đầu ra:  $a1 = Năm - 2000, $a0 = Tháng (1..12), $t5 = Ngày trong tháng (1..31)
d2ymd:  addu  $s6, $ra, $zero
        ori   $t0, $zero, 36584         # Mốc ngày 01/03/2100 (bù năm thế kỷ không nhuận)
        slt   $t1, $a0, $t0
        bne   $t1, $zero, dy1
        addiu $a0, $a0, 1
dy1:    ori   $t1, $zero, 1461          # Chu kỳ 4 năm = 365 * 4 + 1 = 1461 ngày
        div   $a0, $t1
        mflo  $t0
        sll   $a1, $t0, 2               # Năm = (Số chu kỳ 4 năm) * 4
        mfhi  $t5                       # Ngày dư trong chu kỳ 4 năm
        slti  $t1, $t5, 366             # Năm đầu tiên của chu kỳ (năm nhuận) có 366 ngày
        bne   $t1, $zero, dy3
        addiu $t5, $t5, -366
        addiu $a1, $a1, 1
dy2:    slti  $t1, $t5, 365             # Các năm tiếp theo có 365 ngày
        bne   $t1, $zero, dy3
        addiu $t5, $t5, -365
        addiu $a1, $a1, 1
        j     dy2
dy3:    addiu $a0, $zero, 1             # Tìm tháng bắt đầu từ tháng 1
dy4:    jal   mlen
        slt   $t1, $t5, $v0
        bne   $t1, $zero, dy5
        subu  $t5, $t5, $v0
        addiu $a0, $a0, 1
        j     dy4
dy5:    addiu $t5, $t5, 1               # Ngày tính từ 1
        jr    $s6

# ----------------------------------------------------------------------------
# 6. HÀM CHUYỂN ĐỔI NĂM - THÁNG - NGÀY SANG SỐ NGÀY (Y-M-D TO DAYS)
# ----------------------------------------------------------------------------
# Đầu vào: V_SY (Năm), V_SMO (Tháng), V_SD (Ngày)
# Đầu ra:  $v0 = Tổng số ngày tính từ 01/01/2000
ymd2d:  addu  $s6, $ra, $zero
        lw    $a1, V_SY($zero)
        sra   $t0, $a1, 2
        ori   $t1, $zero, 1461
        mul   $t5, $t0, $t1             # Số ngày của các chu kỳ 4 năm chẵn
        andi  $t0, $a1, 3
        beq   $t0, $zero, yd1
        addiu $t1, $zero, 365
        mul   $t0, $t0, $t1
        addu  $t5, $t5, $t0
        addiu $t5, $t5, 1               # Cộng 1 ngày nhuận của năm đầu tiên
yd1:    addiu $a0, $zero, 1
        lw    $t4, V_SMO($zero)
yd2:    beq   $a0, $t4, yd3             # Cộng dồn số ngày của các tháng trước
        jal   mlen
        addu  $t5, $t5, $v0
        addiu $a0, $a0, 1
        j     yd2
yd3:    lw    $t0, V_SD($zero)
        addu  $t5, $t5, $t0
        addiu $v0, $t5, -1             # Trừ 1 để lấy mốc 01/01/2000 là ngày 0
        jr    $s6

# ----------------------------------------------------------------------------
# 7. XỬ LÝ VẼ MÀN HÌNH CHẾ ĐỘ SET
# ----------------------------------------------------------------------------
dr_st:  lw    $t0, V_TPAGE($zero)
        bne   $t0, $zero, dr_st_tmr     # Vẽ màn hình cài đặt Timer Preset
        lw    $t0, V_SF($zero)
        slti  $t1, $t0, 3               # Các trường 0, 1, 2 (Giờ, Phút, Giây)
        beq   $t1, $zero, dst_d
        lw    $t0, V_SH($zero)          # Hiển thị theo bố cục 24h: HH.MM.SS
        addiu $t1, $zero, 60
        mul   $t0, $t0, $t1
        lw    $t2, V_SM($zero)
        addu  $t0, $t0, $t2
        mul   $t0, $t0, $t1
        lw    $t2, V_SS($zero)
        addu  $t0, $t0, $t2
        ori   $t1, $zero, 1000
        mul   $a0, $t0, $t1
        addu  $a1, $zero, $zero
        jal   fmtB
        j     dr_out
dst_d:  lw    $t5, V_SD($zero)          # Các trường 3, 4, 5 (Ngày, Tháng, Năm)
        lw    $a0, V_SMO($zero)
        lw    $a1, V_SY($zero)
        j     dt_dd                     # Hiển thị theo bố cục ngày tháng dd-MM-YY

dr_st_tmr:
        # Hiển thị chuỗi "t1" (Single) hoặc "t2" (Chess) tại D7, D6
        addiu $t0, $zero, CHAR_T
        sw    $t0, D7($zero)
        lw    $t3, V_TP_SUB($zero)
        addiu $t0, $zero, 1             # Số 1 (Single Timer)
        beq   $t3, $zero, dst_t_sub
        addiu $t0, $zero, 2             # Số 2 (Chess Double Clock)
dst_t_sub:
        sw    $t0, D6($zero)
        addiu $t1, $zero, 10
        # Giờ (D5, D4 có dấu chấm)
        lw    $t0, V_TPH($zero)
        div   $t0, $t1
        mflo  $t2                       # Hàng chục Giờ (D5)
        sw    $t2, D5($zero)
        mfhi  $t2                       # Hàng đơn vị Giờ (D4)
        ori   $t2, $t2, CHAR_DP         # Bật dấu chấm sau Giờ
        sw    $t2, D4($zero)
        # Phút (D3, D2 có dấu chấm)
        lw    $t0, V_TPM($zero)
        div   $t0, $t1
        mflo  $t2                       # Hàng chục Phút (D3)
        sw    $t2, D3($zero)
        mfhi  $t2                       # Hàng đơn vị Phút (D2)
        ori   $t2, $t2, CHAR_DP         # Bật dấu chấm sau Phút
        sw    $t2, D2($zero)
        # Giây (D1, D0)
        lw    $t0, V_TPS($zero)
        div   $t0, $t1
        mflo  $t2                       # Hàng chục Giây (D1)
        sw    $t2, D1($zero)
        mfhi  $t2                       # Hàng đơn vị Giây (D0)
        sw    $t2, D0($zero)
        j     dr_out
