# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/main.s — Chương Trình Chính Đồng Hồ Số WatchChip (Main Entry)
# VAI TRÒ:        Điều phối toàn diện 5 chế độ hoạt động (TIME, STOPWATCH,
#                 TIMER, ALARM, SET), xử lý vòng lặp chính, định tuyến
#                 sự kiện và hiển thị LED 7 đoạn đa hợp.
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Kiến Trúc Phần Mềm Nhúng Đơn Nhiệm (Embedded Super-Loop Architecture):
#      Firmware thực thi theo mô hình vòng lặp vô hạn (Super-Loop):
#        events() -> ringchk() -> sync() -> draw() -> lặp lại.
#      Tất cả các tác vụ kiểm tra nút bấm, xử lý âm thanh, đồng bộ thời gian
#      và cập nhật giao diện hiển thị được phân bổ đồng đều trong mỗi chu trình.
#    - Tái Cấu Trúc Mã Nguồn Module Hóa (Modular Firmware Architecture):
#      Toàn bộ các quy tắc định nghĩa MMIO và vùng nhớ DMEM được đóng gói trong
#      fw/mmio.inc và fw/def.inc. Từng chế độ FSM được bóc tách độc lập thành
#      các tệp hợp ngữ chuyên biệt và tích hợp qua chỉ thị .include.
# ============================================================================

.include "fw/def.inc"
.include "fw/mmio.inc"

        j     boot

.include "fw/isr.s"
.include "fw/boot.s"

# ----------------------------------------------------------------------------
# VÒNG LẶP ĐIỀU PHỐI CHÍNH (MAIN SUPER-LOOP)
# ----------------------------------------------------------------------------
loop:   jal   events                    # 1. Quét và điều phối sự kiện nút bấm
        jal   ringchk                   # 2. Kiểm tra chuông còi báo thức / hẹn giờ
        jal   sync                      # 3. Tiếp nhận và xử lý đồng bộ thời gian UART
        jal   draw                      # 4. Cập nhật và quét bộ đệm hiển thị LED
        j     loop

# ============================================================================
# BỘ ĐIỀU PHỐI SỰ KIỆN NÚT BẤM (BUTTON EVENT DISPATCHER)
# ============================================================================
events: lw    $t0, REG_BTN_EVENT($zero) # Đọc sự kiện nút từ FIFO phần cứng
        slt   $t1, $t0, $zero           # Bit 31 (VALID) = 1 nếu có sự kiện mới
        beq   $t1, $zero, ev_ret        # Không có sự kiện: Trở về
        sra   $t1, $t0, 29
        andi  $a0, $t1, 3               # Mã nút bấm: 0: MODE, 1: A, 2: B, 3: C
        lui   $t1, 0x07ff
        ori   $t1, $t1, 0xffff
        and   $a1, $t0, $t1             # Tem thời gian lúc nhấn (mili-giây)
        lw    $t2, V_RING($zero)
        beq   $t2, $zero, ev_norm       # Không đổ chuông: Xử lý chức năng thông thường

        # Đang đổ chuông: Bất kỳ nút nào cũng tắt chuông còi
        sw    $zero, REG_BEEP_PAT($zero) # Ngắt còi PWM
        sw    $zero, V_RING($zero)      # Trở về trạng thái im lặng
        addiu $t1, $zero, 3
        bne   $a0, $t1, ev_ret          # Không phải nút C: Chỉ tắt chuông
        addiu $t1, $zero, 2
        beq   $t2, $t1, ev_snz_act      # Chuông báo thức: Kích hoạt Snooze
        addiu $t1, $zero, 1
        bne   $t2, $t1, ev_ret          # Không phải chuông Timer: Thoát
        # Chuông Timer và bấm C: Vừa tắt chuông vừa TẠM DỪNG (Pause) ngay lập tức trong 1 lần nhấn!
        addiu $t3, $zero, 4             # CLR=0, BEEP_EN=1, RUN=0 (dừng timer)
        sw    $t3, REG_TMR_CTRL($zero)
        addiu $t3, $zero, 1
        sw    $t3, V_TPAUSED($zero)     # Bật cờ tạm dừng
        j     ev_ret

ev_snz_act:
        # Phím C khi đang chuông báo thức: Kích hoạt chế độ Snooze (+5 phút)
        lui   $t1, 4
        ori   $t1, $t1, 0x93e0          # 300.000 ms = 5 phút
        addu  $a1, $a1, $t1
        lui   $t1, 0x0526
        ori   $t1, $t1, 0x5c00          # 86.400.000 ms
        slt   $t2, $a1, $t1
        bne   $t2, $zero, ev_snz
        subu  $a1, $a1, $t1             # Bù vòng ngày nếu vượt qua nửa đêm
ev_snz: sw    $a1, V_SNZ($zero)
        addiu $t1, $zero, 1
        sw    $t1, V_SNZON($zero)       # Bật cờ hẹn lại chuông Snooze
ev_ret: jr    $ra

ev_norm: addiu $t1, $zero, 1
        sw    $t1, REG_BEEP_PAT($zero)  # Phát tiếng bíp ngắn 64ms phản hồi nhấn nút
        lw    $t3, V_MODE($zero)
        bne   $a0, $zero, ev_btn        # Các nút A, B, C: Định tuyến vào chế độ hiện tại

        # Nếu đang ở SET (Mode 4): Nút MODE chuyển giữa các trang SET (0 -> 1 -> 2 -> 3 -> 4 -> Mode 0)
        addiu $t1, $zero, 4
        bne   $t3, $t1, em_mode_norm
        lw    $t4, V_TPAGE($zero)
        addiu $t4, $t4, 1
        addiu $t1, $zero, 5
        bne   $t4, $t1, em_set_page
        # Quá trang 4 (5 trang: 0..4): Thoát SET về TIME (Mode 0)
        sw    $zero, V_MODE($zero)
        sw    $zero, V_TPAGE($zero)
        sw    $zero, REG_BLINK_MASK($zero)
        jr    $ra
em_set_page:
        sw    $t4, V_TPAGE($zero)
        j     set_in                    # Nạp ngữ cảnh tương ứng cho trang mới

em_mode_norm:
        # Nút MODE: Chuyển đổi trạng thái FSM (TIME 0 -> ALARM 1 -> SW 2 -> TMR 3 -> SET 4 -> TIME 0)
        addiu $t1, $zero, 2             # Rời STOPWATCH: Mode 2
        bne   $t3, $t1, em1
        lw    $t0, REG_SW_CTRL($zero)   # Rời STOPWATCH: Tắt SRC=0, giữ nguyên cờ RUN
        andi  $t0, $t0, 1
        sw    $t0, REG_SW_CTRL($zero)
        sw    $zero, V_LAPI($zero)
em1:    sw    $zero, REG_BLINK_MASK($zero) # Tắt nhấp nháy LED
        sw    $zero, V_AED($zero)
        sw    $zero, V_TPAGE($zero)     # Reset trang SET về 0 (RTC) khi đổi mode
        addiu $t3, $t3, 1
        addiu $t1, $zero, 5
        bne   $t3, $t1, em2
        addu  $t3, $zero, $zero         # Quá 4: Quay về chế độ 0 (TIME)
em2:    sw    $t3, V_MODE($zero)
        addiu $t1, $zero, 2             # Vào STOPWATCH: Mode 2
        bne   $t3, $t1, em3
        addiu $t0, $zero, 4
        sw    $t0, REG_SW_CTRL($zero)   # Vào STOPWATCH: Bật SRC=1 (phần cứng capture trực tiếp)
        jr    $ra
em3:    addiu $t1, $zero, 4
        beq   $t3, $t1, set_in          # Vào SET: Nạp giờ hiện tại vào các trường chỉnh sửa
        jr    $ra

ev_btn: beq   $t3, $zero, tm_btn        # Chế độ 0: TIME
        addiu $t1, $zero, 1
        beq   $t3, $t1, al_btn          # Chế độ 1: ALARM (ngay sau TIME)
        addiu $t1, $zero, 2
        beq   $t3, $t1, sw_btn          # Chế độ 2: STOPWATCH
        addiu $t1, $zero, 3
        beq   $t3, $t1, tr_btn          # Chế độ 3: TIMER / CHESS
        j     st_btn                    # Chế độ 4: SET

# ============================================================================
# NHÚNG CÁC MÔ-ĐUN HỢP NGỮ THEO CHẾ ĐỘ HOẠT ĐỘNG
# ============================================================================
.include "fw/time_mode.s"
.include "fw/sw_mode.s"
.include "fw/timer_mode.s"
.include "fw/alarm_mode.s"
.include "fw/set_mode.s"
.include "fw/uart_sync.s"

# ============================================================================
# BỘ ĐIỀU PHỐI VẼ MÀN HÌNH LED 7 ĐOẠN (DISPLAY ROUTER & FORMATTERS)
# ============================================================================
draw:   addu  $s7, $ra, $zero
        lw    $t3, V_MODE($zero)
        beq   $t3, $zero, dr_tm         # Chế độ 0: TIME
        addiu $t1, $zero, 1
        beq   $t3, $t1, dr_al           # Chế độ 1: ALARM
        addiu $t1, $zero, 2
        beq   $t3, $t1, dr_sw           # Chế độ 2: STOPWATCH
        addiu $t1, $zero, 3
        beq   $t3, $t1, dr_tr           # Chế độ 3: TIMER
        j     dr_st                     # Chế độ 4: SET
dr_out: jal   flush
        jr    $s7

# fmtD: ms >= 0 -> Nếu >= 360.000.000 ms: "--.--.--"; nếu >= 1h: fmtB; ngược lại fmtA
fmtD:   lui   $t1, 0x1575
        ori   $t1, $t1, 0x2a00          # 360.000.000 ms
        slt   $t0, $a0, $t1
        beq   $t0, $zero, fd_x
        lui   $t1, 0x36
        ori   $t1, $t1, 0xee80          # 3.600.000 ms
        slt   $t0, $a0, $t1
        bne   $t0, $zero, fmtA
        addu  $a1, $zero, $zero
        j     fmtB
fd_x:   addiu $t0, $zero, CHAR_DASH
        sw    $t0, D0($zero)
        sw    $t0, D1($zero)
        sw    $t0, D3($zero)
        sw    $t0, D5($zero)
        addiu $t0, $zero, 0x99          # '-' kèm dấu chấm (0x19 | 0x80)
        sw    $t0, D2($zero)
        sw    $t0, D4($zero)
        addiu $t0, $zero, CHAR_BLANK
        sw    $t0, D6($zero)
        sw    $t0, D7($zero)
        jr    $ra

# fmtA: ms < 3.600.000 -> "_MM.SS.mmm"
fmtA:   addu  $s5, $ra, $zero
        ori   $t1, $zero, 60000
        div   $a0, $t1
        mflo  $t0
        mfhi  $t2
        lui   $t1, 1
        ori   $t1, $t1, 0x86a0          # 100.000
        mul   $t0, $t0, $t1
        addu  $a0, $t0, $t2
        addiu $a1, $zero, 7
        jal   putd
        addiu $t0, $zero, CHAR_BLANK
        sw    $t0, D7($zero)
        lw    $t0, D5($zero)
        ori   $t0, $t0, CHAR_DP
        sw    $t0, D5($zero)
        lw    $t0, D3($zero)
        ori   $t0, $t0, CHAR_DP
        sw    $t0, D3($zero)
        jr    $s5

# fmtB: ms (< 100h), $a1 = 1 nếu 12h -> "__HH.MM.SS" / "A_HH.MM.SS" / "P_HH.MM.SS"
fmtB:   addu  $s5, $ra, $zero
        ori   $t1, $zero, 1000
        div   $a0, $t1
        mflo  $t0                       # Tổng số giây
        addiu $t1, $zero, 3600
        div   $t0, $t1
        mflo  $t2                       # Giờ
        mfhi  $t0
        addiu $t1, $zero, 60
        div   $t0, $t1
        mflo  $t3                       # Phút
        mfhi  $t4                       # Giây
        addiu $t6, $zero, CHAR_BLANK
        beq   $a1, $zero, fb2
        addiu $t6, $zero, 0x0a          # Ký tự 'A' (AM)
        slti  $t1, $t2, 12
        bne   $t1, $zero, fb1
        addiu $t6, $zero, 0x14          # Ký tự 'P' (PM)
        addiu $t2, $t2, -12
fb1:    bne   $t2, $zero, fb2
        addiu $t2, $zero, 12            # 0h quy đổi thành 12h
fb2:    addiu $t1, $zero, 10000
        mul   $t2, $t2, $t1
        addiu $t1, $zero, 100
        mul   $t3, $t3, $t1
        addu  $a0, $t2, $t3
        addu  $a0, $a0, $t4             # HH MM SS
        addiu $a1, $zero, 6
        jal   putd
        sw    $t6, D7($zero)            # Ký tự AM/PM hoặc khoảng trắng
        addiu $t0, $zero, CHAR_BLANK
        addiu $t1, $zero, CHAR_BLANK
        beq   $t6, $t1, fb_d6
        addiu $t0, $zero, CHAR_M        # Ký tự 'M' cho AM/PM
fb_d6:  sw    $t0, D6($zero)
        lw    $t0, D4($zero)
        ori   $t0, $t0, CHAR_DP         # Dấu chấm ngăn cách Giờ và Phút
        sw    $t0, D4($zero)
        lw    $t0, D2($zero)
        ori   $t0, $t0, CHAR_DP         # Dấu chấm ngăn cách Phút và Giây
        sw    $t0, D2($zero)
        jr    $s5

# putd: $a0 = số nguyên thập phân (< 10^8), $a1 = số chữ số -> Ghi vào mảng D0..D(a1-1)
putd:   bcd   $t0, $a0                  # Chuyển đổi nhị phân sang BCD phần cứng
        addiu $t1, $zero, D0
pd1:    andi  $t2, $t0, 0xf             # Lấy 4-bit chữ số BCD
        sw    $t2, 0($t1)
        sra   $t0, $t0, 4
        addiu $t1, $t1, 4
        addiu $a1, $a1, -1
        bne   $a1, $zero, pd1
        jr    $ra

# flush: Chuyển dữ liệu từ bộ đệm bóng D0..D7 ra thanh ghi phần cứng DISP0..DISP7
flush:  addiu $t1, $zero, D0
        addiu $t2, $zero, REG_DISP0
        addiu $t3, $zero, REG_BLINK_MASK
fl1:    lw    $t0, 0($t1)
        sw    $t0, 0($t2)
        addiu $t1, $t1, 4
        addiu $t2, $t2, 4
        bne   $t2, $t3, fl1
        jr    $ra
