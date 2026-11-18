# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/alarm_mode.s — Xử Lý Chế Độ Báo Thức & Chuông Còi (ALARM Mode)
# VAI TRÒ:        Quản lý 4 mốc báo thức độc lập, tính năng chuông điểm giờ tròn
#                 tiếng (Hourly Chime), tạm hoãn chuông (Snooze +5 phút),
#                 tự động tắt sau 60s và giao diện chỉnh sửa giờ báo thức.
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Quản Lý Báo Thức Đa Kênh (Multi-Channel Alarm Scheduling):
#      Phần cứng hỗ trợ 4 thanh ghi báo thức REG_ALARM0..REG_ALARM3. Mỗi thanh
#      ghi gồm mặt nạ ngày trong tuần (bits [22:16]), cờ EN (bit 31), cờ HIT
#      (bit 23) và số phút trong ngày (bits [10:0]).
#    - Thuật Toán Snooze & Tự Tắt (Snooze Logic & Auto-Silence):
#      Khi chuông reo, nhấn phím C sẽ hoãn chuông: Tính thời điểm kêu lại
#      V_SNZ = (Thời điểm nhấn + 300.000 ms) mod 86.400.000 ms.
#      Nếu không ai bấm tắt, chuông tự động ngắt sau 60 giây (60.000 ms).
# ============================================================================

# ----------------------------------------------------------------------------
# 1. XỬ LÝ SỰ KIỆN NÚT BẤM TRONG CHẾ ĐỘ ALARM
# ----------------------------------------------------------------------------
al_btn: lw    $t4, V_ALK($zero)         # Chỉ số kênh báo thức đang chọn (0..3: AL1..AL4, 4: Chime)
        lw    $t5, V_AED($zero)         # Cờ đang sửa: 0: Không sửa, 1: Sửa giờ, 2: Sửa phút
        sll   $t6, $t4, 2
        addiu $t6, $t6, REG_ALARM0      # Địa chỉ thanh ghi ALARMk tương ứng
        addiu $t1, $zero, 1
        bne   $a0, $t1, al_b
        bne   $t5, $zero, al_inc        # Nút A khi đang ở chế độ sửa: Tăng giá trị
        addiu $t1, $zero, 4
        bne   $t4, $t1, al_en
        lw    $t0, V_CHIME($zero)       # Nút A ở trang Chuông giờ: Đảo bật/tắt (0 <-> 1)
        addiu $t1, $zero, 1
        subu  $t0, $t1, $t0
        sw    $t0, V_CHIME($zero)
        jr    $ra
al_en:  lw    $t0, 0($t6)               # Nút A ở AL1..AL4: Đảo bit cho phép EN (bit 31)
        lui   $t1, 0x8000
        xor   $t0, $t0, $t1
        sw    $t0, 0($t6)
        jr    $ra
al_inc: addiu $t1, $zero, 1             # Tăng trường đang sửa (+1 giờ hoặc +1 phút)
        bne   $t5, $t1, al_im
        lw    $t0, V_AEH($zero)         # Tăng giờ: 0..23 quay vòng về 0
        addiu $t0, $t0, 1
        addiu $t1, $zero, 24
        bne   $t0, $t1, al_ih
        addu  $t0, $zero, $zero
al_ih:  sw    $t0, V_AEH($zero)
        jr    $ra
al_im:  lw    $t0, V_AEM($zero)         # Tăng phút: 0..59 quay vòng về 0
        addiu $t0, $t0, 1
        addiu $t1, $zero, 60
        bne   $t0, $t1, al_im1
        addu  $t0, $zero, $zero
al_im1: sw    $t0, V_AEM($zero)
        jr    $ra
al_b:   addiu $t1, $zero, 2
        bne   $a0, $t1, al_c
        bne   $t5, $zero, al_bf
        addiu $t4, $t4, 1               # Nút B: Chuyển kênh AL1 -> AL2 -> AL3 -> AL4 -> CHIME -> AL1
        addiu $t1, $zero, 5
        bne   $t4, $t1, al_b1
        addu  $t4, $zero, $zero
al_b1:  sw    $t4, V_ALK($zero)
        jr    $ra
al_bf:  addiu $t1, $zero, 3             # Nút B khi đang sửa: Chuyển đổi giữa sửa Giờ (1) <-> Phút (2)
        subu  $t5, $t1, $t5
        sw    $t5, V_AED($zero)
        j     al_bl
al_c:   addiu $t1, $zero, 4
        beq   $t4, $t1, al_r            # Ở trang Chuông giờ: Nút C không có tác dụng sửa
        bne   $t5, $zero, al_sv
        lw    $t0, 0($t6)               # Nút C: Bắt đầu vào chế độ sửa giờ báo thức
        andi  $t0, $t0, 0x7ff          # Trích xuất 11-bit số phút trong ngày
        addiu $t1, $zero, 60
        div   $t0, $t1                  # Giờ = Phút / 60, Phút = Phút % 60
        mflo  $t2
        sw    $t2, V_AEH($zero)
        mfhi  $t2
        sw    $t2, V_AEM($zero)
        addiu $t5, $zero, 1             # Đặt cờ bắt đầu sửa giờ
        sw    $t5, V_AED($zero)
al_bl:  addiu $t0, $zero, 0x0c          # Mặt nạ nhấp nháy 2 Hz: Sửa giờ nháy DISP3, DISP2
        addiu $t1, $zero, 1
        beq   $t5, $t1, al_bl1
        addiu $t0, $zero, 0x03          # Sửa phút nháy DISP1, DISP0
al_bl1: sw    $t0, REG_BLINK_MASK($zero) # Ghi vào thanh ghi mặt nạ nhấp nháy
al_r:   jr    $ra
al_sv:  lw    $t0, 0($t6)               # Nút C khi đang sửa: Lưu giá trị giờ/phút mới vào phần cứng
        lui   $t1, 0xff00
        and   $t0, $t0, $t1             # Bảo tồn cờ EN và mặt nạ ngày DAYMASK
        lw    $t2, V_AEH($zero)
        addiu $t1, $zero, 60
        mul   $t2, $t2, $t1
        lw    $t1, V_AEM($zero)
        addu  $t2, $t2, $t1             # Tính lại tổng số phút trong ngày
        or    $t0, $t0, $t2
        sw    $t0, 0($t6)               # Ghi lại thanh ghi phần cứng
        sw    $zero, V_AED($zero)       # Thoát chế độ sửa
        sw    $zero, REG_BLINK_MASK($zero) # Tắt nhấp nháy LED
        jr    $ra

# ----------------------------------------------------------------------------
# 2. TIẾN TRÌNH QUẢN LÝ CHUÔNG BÁO VÀ TỰ ĐỘNG TẮT (RING CHECK ROUTINE)
# ----------------------------------------------------------------------------
ringchk: mtc0 $zero, $12                # Tắt ngắt tạm thời để đọc nguyên tử
        lw    $s4, REG_RTC_MS($zero)    # Lấy mili-giây hiện tại trong ngày
        lw    $a2, REG_DAY_SHADOW($zero) # Lấy ngày hiện tại
        addiu $t0, $zero, USE_IRQ
        mtc0  $t0, $12                  # Bật lại ngắt
        lw    $t0, REG_TMR_CTRL($zero)  # 1) Kiểm tra sự kiện hết giờ đếm lùi
        andi  $t1, $t0, 2               # Bit ZERO
        beq   $t1, $zero, rc2
        andi  $t0, $t0, 0xd
        ori   $t0, $t0, 2               # Xóa cờ ZERO (W1C), bảo toàn các cờ khác
        sw    $t0, REG_TMR_CTRL($zero)
        lw    $t2, V_TMR_STP0($zero)
        beq   $t2, $zero, rc1_send
        sw    $zero, REG_TMR_CTRL($zero) # STP0 = 1: Dừng bộ đếm
        sw    $zero, REG_TMR_VALUE($zero) # Khóa tại đúng 0 ms
rc1_send:
        addu  $s1, $ra, $zero
        addiu $a0, $zero, 0x5a          # Gửi gói tin thông báo "$Z" qua UART lên PC
        addu  $a1, $s4, $zero
        jal   sy_send
        addu  $ra, $s1, $zero
        addiu $t0, $zero, 1             # Trạng thái chuông = 1 (Timer ring)
        j     rc_on
rc2:    lw    $t0, REG_IRQ_PENDING($zero) # 2) Kiểm tra cờ ngắt báo thức (bit 3)
        andi  $t0, $t0, IRQ_BIT_ALARM
        beq   $t0, $zero, rc3
        addiu $t0, $zero, IRQ_BIT_ALARM
        sw    $t0, REG_IRQ_PENDING($zero) # Xóa cờ ngắt báo thức (W1C)
        addiu $t2, $zero, REG_ALARM0
rc2a:   lw    $t0, 0($t2)               # Xóa cờ HIT trên từng kênh báo thức
        lui   $t1, 0x80
        and   $t1, $t0, $t1
        beq   $t1, $zero, rc2b
        sw    $t0, 0($t2)
rc2b:   addiu $t2, $t2, 4
        addiu $t1, $zero, -192
        bne   $t2, $t1, rc2a
        sw    $zero, V_SNZON($zero)      # Tắt cờ Snooze nếu đang bật
        j     rc_al
rc3:    lw    $t0, V_SNZON($zero)       # 3) Kiểm tra mốc hẹn giờ lặp lại Snooze
        beq   $t0, $zero, rc4
        lw    $t0, V_SNZ($zero)
        subu  $t0, $s4, $t0             # Hiệu thời gian = Hiện tại - Giờ hẹn Snooze
        slt   $t1, $t0, $zero
        beq   $t1, $zero, rc3a
        lui   $t1, 0x0526
        ori   $t1, $t1, 0x5c00          # Bù vòng ngày (86.400.000 ms)
        addu  $t0, $t0, $t1
rc3a:   ori   $t1, $zero, 60000
        slt   $t1, $t0, $t1
        beq   $t1, $zero, rc4           # Chưa tới khoảng 60s hợp lệ
        sw    $zero, V_SNZON($zero)
rc_al:  lui   $t0, 1
        ori   $t0, $t0, 0x0f0f          # Mẫu chuông báo thức dồn dập 0x10F0F
        sw    $t0, REG_BEEP_PAT($zero)
        addiu $t0, $zero, 2             # Trạng thái chuông = 2 (Alarm ring)
rc_on:  sw    $t0, V_RING($zero)
        sw    $s4, V_RINGT($zero)       # Lưu thời điểm bắt đầu đổ chuông
        jr    $ra
rc4:    lw    $t0, V_RING($zero)        # 4) Tự động ngắt chuông sau 60 giây
        beq   $t0, $zero, rc5
        lw    $t0, V_RINGT($zero)
        subu  $t0, $s4, $t0
        slt   $t1, $t0, $zero
        beq   $t1, $zero, rc4a
        lui   $t1, 0x0526
        ori   $t1, $t1, 0x5c00
        addu  $t0, $t0, $t1
rc4a:   lw    $t1, V_ALM_DUR($zero)
        slt   $t1, $t0, $t1
        bne   $t1, $zero, rc5           # Chưa đủ thời lượng chuông cài đặt
        sw    $zero, REG_BEEP_PAT($zero) # Ngắt còi PWM
        sw    $zero, V_RING($zero)      # Trở về trạng thái im lặng
rc5:    lui   $t1, 0x36                 # 5) Phát chuông báo giờ tròn tiếng (Hourly Chime)
        ori   $t1, $t1, 0xee80          # 3.600.000 ms = 1 giờ
        div   $s4, $t1
        mflo  $t0                       # Lấy chỉ số giờ hiện tại
        lw    $t2, V_LASTH($zero)
        sw    $t0, V_LASTH($zero)
        beq   $t0, $t2, rc_r            # Giờ chưa đổi: Không làm gì
        slt   $t1, $t2, $zero
        bne   $t1, $zero, rc_r          # Vừa nạp giờ lúc boot: Bỏ qua
        lw    $t1, V_CHIME($zero)
        beq   $t1, $zero, rc_r          # Tính năng Chime đang tắt
        lw    $t1, V_RING($zero)
        bne   $t1, $zero, rc_r          # Đang đổ chuông khác: Không chồng âm
        addiu $t1, $zero, 5
        sw    $t1, REG_BEEP_PAT($zero)  # Phát 2 tiếng bíp kép báo chuyển canh giờ
rc_r:   jr    $ra

# ----------------------------------------------------------------------------
# 3. XỬ LÝ VẼ MÀN HÌNH CHẾ ĐỘ ALARM
# ----------------------------------------------------------------------------
dr_al:  lw    $t4, V_ALK($zero)
        addiu $t1, $zero, 4
        bne   $t4, $t1, da1
        addiu $t0, $zero, CHAR_BLANK    # Trang chuông giờ hiển thị "CH o    "
        sw    $t0, D0($zero)
        sw    $t0, D1($zero)
        sw    $t0, D2($zero)
        sw    $t0, D3($zero)
        sw    $t0, D5($zero)
        lw    $t1, V_CHIME($zero)
        beq   $t1, $zero, da0
        addiu $t0, $zero, 0x13          # Ký tự 'o' (On)
da0:    sw    $t0, D4($zero)
        addiu $t0, $zero, 0x0c          # Ký tự 'C'
        sw    $t0, D7($zero)
        addiu $t0, $zero, 0x10          # Ký tự 'H'
        sw    $t0, D6($zero)
        j     dr_out
da1:    sll   $t6, $t4, 2
        addiu $t6, $t6, REG_ALARM0
        lw    $t5, 0($t6)               # Đọc giá trị thanh ghi báo thức phần cứng
        andi  $a0, $t5, 0x7ff
        lw    $t0, V_AED($zero)
        beq   $t0, $zero, da2
        lw    $a0, V_AEH($zero)         # Đang trong chế độ sửa: Hiển thị giá trị đang sửa
        addiu $t1, $zero, 60
        mul   $a0, $a0, $t1
        lw    $t1, V_AEM($zero)
        addu  $a0, $a0, $t1
da2:    addiu $t1, $zero, 60            # Định dạng chuỗi "ALk.o HH.MM"
        div   $a0, $t1
        mflo  $t0
        mfhi  $t2
        addiu $t1, $zero, 100
        mul   $t0, $t0, $t1
        addu  $a0, $t0, $t2
        addiu $a1, $zero, 4
        jal   putd
        lw    $t0, D2($zero)
        ori   $t0, $t0, CHAR_DP         # Dấu chấm ngăn cách Giờ và Phút
        sw    $t0, D2($zero)
        addiu $t0, $zero, 0x0a          # Ký tự 'A'
        sw    $t0, D7($zero)
        addiu $t0, $zero, 0x11          # Ký tự 'L'
        sw    $t0, D6($zero)
        addiu $t0, $t4, 1               # Số hiệu báo thức (1..4)
        sw    $t0, D5($zero)
        addiu $t0, $zero, CHAR_BLANK
        slt   $t1, $t5, $zero           # Bit EN (bit 31)
        beq   $t1, $zero, da3
        addiu $t0, $zero, 0x13          # Ký tự 'o' (On) nếu đang bật
da3:    sw    $t0, D4($zero)
        j     dr_out
