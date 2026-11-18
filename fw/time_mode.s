# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/time_mode.s — Xử Lý Chế Độ Đồng Hồ Thời Gian Thực (TIME Mode)
# VAI TRÒ:        Xử lý sự kiện nút bấm và hiển thị chế độ TIME:
#                 - Phím A: Smash Alarm (tắt còi tức thì) & Triple-Click Global Off
#                 - Phím B: Xoay vòng 4 Views (12h AM/PM -> 24h+ms -> Date -> W03  THU)
#                 - Phím C: Đổi màu LED 4 màu (Đỏ -> Xanh lá -> Xanh lam nhạt -> Vàng)
# ============================================================================

# ----------------------------------------------------------------------------
# 1. XỬ LÝ SỰ KIỆN NÚT BẤM TRONG CHẾ ĐỘ TIME
# ----------------------------------------------------------------------------
tm_btn: addiu $t1, $zero, 1
        bne   $a0, $t1, tm_b

        # ---------------- NÚT A: SMASH ALARM & TRIPLE-CLICK GLOBAL OFF ----------------
        # 1. Tắt còi báo động / chuông điểm giờ / snooze tức thì (Smash Alarm)
        sw    $zero, REG_BEEP_PAT($zero)
        sw    $zero, V_RING($zero)
        sw    $zero, V_SNZON($zero)

        # 2. Kiểm tra bấm nhanh 3 lần liên tiếp (Triple-click <= 600 ms)
        lw    $t0, REG_RTC_MS($zero)
        lw    $t2, V_A_LAST($zero)
        subu  $t3, $t0, $t2
        slt   $t1, $t3, $zero
        bne   $t1, $zero, tm_a_first     # Sang ngày mới (dư âm)
        addiu $t1, $zero, 600
        slt   $t2, $t1, $t3
        bne   $t2, $zero, tm_a_first     # Khoảng cách > 600 ms

        # Khoảng cách <= 600 ms: Tăng biến đếm
        lw    $t1, V_A_CNT($zero)
        addiu $t1, $t1, 1
        sw    $t1, V_A_CNT($zero)
        sw    $t0, V_A_LAST($zero)
        addiu $t2, $zero, 3
        slt   $t3, $t1, $t2
        bne   $t3, $zero, tm_a_ret

        # Đủ 3 lần bấm liên tiếp: GLOBAL ALARM TURN OFF!
        sw    $zero, V_A_CNT($zero)
        addiu $t1, $zero, 1
        sw    $t1, V_GLB_ALM_OFF($zero)
        sw    $zero, V_CHIME($zero)     # Tắt Hourly Chime
        # Xóa cờ EN (bit 31) ở cả 4 kênh báo thức phần cứng REG_ALARM0..3
        lui   $t1, 0x7fff
        ori   $t1, $t1, 0xffff
        lw    $t0, REG_ALARM0($zero)
        and   $t0, $t0, $t1
        sw    $t0, REG_ALARM0($zero)
        lw    $t0, REG_ALARM1($zero)
        and   $t0, $t0, $t1
        sw    $t0, REG_ALARM1($zero)
        lw    $t0, REG_ALARM2($zero)
        and   $t0, $t0, $t1
        sw    $t0, REG_ALARM2($zero)
        lw    $t0, REG_ALARM3($zero)
        and   $t0, $t0, $t1
        sw    $t0, REG_ALARM3($zero)
        jr    $ra

tm_a_first:
        addiu $t1, $zero, 1
        sw    $t1, V_A_CNT($zero)
        sw    $t0, V_A_LAST($zero)
tm_a_ret:
        jr    $ra

tm_b:   addiu $t1, $zero, 2
        bne   $a0, $t1, tm_c

        # ---------------- NÚT B: CHUYỂN 4 VIEW HIỂN THỊ ----------------
        # View 0: 12h AM/PM
        # View 1: 24h with 2-digit ms (0.01s)
        # View 2: Date 29022024 (DD.MM.YYYY)
        # View 3: WeekNum & DayinWeek (W03  THU)
        lw    $t0, V_TV($zero)
        addiu $t0, $t0, 1
        addiu $t1, $zero, 4
        bne   $t0, $t1, tm_b_save
        addu  $t0, $zero, $zero
tm_b_save:
        sw    $t0, V_TV($zero)
        jr    $ra

tm_c:   # ---------------- NÚT C: ĐỔI MÀU LED 4 MÀU ----------------
        # 0: Đỏ, 1: Xanh lá, 2: Xanh lam nhạt (Cyan), 3: Vàng
        lw    $t0, V_COLOR($zero)
        addiu $t0, $t0, 1
        addiu $t1, $zero, 4
        bne   $t0, $t1, tm_c_save
        addu  $t0, $zero, $zero
tm_c_save:
        sw    $t0, V_COLOR($zero)
        jr    $ra

# ----------------------------------------------------------------------------
# 2. XỬ LÝ VẼ MÀN HÌNH CHẾ ĐỘ TIME
# ----------------------------------------------------------------------------
dr_tm:  mtc0  $zero, $12                # Tắt ngắt tạm thời để đọc nguyên tử cặp MS và DAY
        lw    $a0, REG_RTC_MS($zero)    # Đọc mili-giây trong ngày
        lw    $t4, REG_DAY_SHADOW($zero)# Đọc ngày chốt cùng khoảnh khắc
        addiu $t0, $zero, USE_IRQ
        mtc0  $t0, $12                  # Khôi phục trạng thái ngắt

        lw    $t0, V_TV($zero)
        beq   $t0, $zero, dt_12h        # View 0: 12h AM/PM
        addiu $t1, $zero, 1
        beq   $t0, $t1, dt_24h_ms       # View 1: 24h + 2-digit ms (0.01s)
        addiu $t1, $zero, 2
        beq   $t0, $t1, dt_date         # View 2: Ngày DD.MM.YYYY
        j     dt_week                   # View 3: Tuần & Thứ (W03  THU)

# View 0: 12h AM/PM (fmtB với $a1 = 1) -> AM 10.25.30 / PM 11.45.12
dt_12h: addiu $a1, $zero, 1
        jal   fmtB
        j     dr_out

# View 1: 24h với độ chính xác 0.01s (HH.MM.SS.cc) -> 8 chữ số, chấm tại D6, D4, D2
dt_24h_ms:
        ori   $t1, $zero, 1000
        div   $a0, $t1
        mflo  $t0                       # t0 = tổng số giây trong ngày (0..86399)
        mfhi  $t1                       # mili-giây dư (0..999)
        ori   $t2, $zero, 10
        div   $t1, $t2
        mflo  $t5                       # t5 = centiseconds cc (0..99)

        addiu $t1, $zero, 3600
        div   $t0, $t1
        mflo  $t2                       # t2 = Giờ (0..23)
        mfhi  $t0
        addiu $t1, $zero, 60
        div   $t0, $t1
        mflo  $t3                       # t3 = Phút (0..59)
        mfhi  $t4                       # t4 = Giây (0..59)

        # Ghép 8 chữ số: ((hr * 100 + min) * 100 + sec) * 100 + cc
        addiu $t1, $zero, 100
        mul   $t2, $t2, $t1
        addu  $t2, $t2, $t3             # hr*100 + min
        mul   $t2, $t2, $t1
        addu  $t2, $t2, $t4             # (hr*100+min)*100 + sec
        mul   $t2, $t2, $t1
        addu  $a0, $t2, $t5             # ((hr*100+min)*100+sec)*100 + cc
        addiu $a1, $zero, 8
        jal   putd

        # Bật dấu chấm ngăn cách: D6 (Giờ), D4 (Phút), D2 (Giây)
        lw    $t0, D6($zero)
        ori   $t0, $t0, CHAR_DP
        sw    $t0, D6($zero)
        lw    $t0, D4($zero)
        ori   $t0, $t0, CHAR_DP
        sw    $t0, D4($zero)
        lw    $t0, D2($zero)
        ori   $t0, $t0, CHAR_DP
        sw    $t0, D2($zero)
        j     dr_out

# View 2: Ngày DD.MM.YYYY (8 chữ số, chấm tại D6, D4) -> ví dụ 29.02.2024
dt_date:
        andi  $a0, $t4, 0xffff          # Trích xuất 16-bit số ngày từ mốc 01/01/2000
        jal   d2ymd                     # Trả về: $t5 = Day, $a0 = Month, $a1 = Yr (tính từ 2000)
dt_dd:  addiu $a1, $a1, 2000            # Full year YYYY (ví dụ 2024, 2026)
        # N = (Day * 100 + Month) * 10000 + Year
        addiu $t1, $zero, 100
        mul   $t5, $t5, $t1
        addu  $t5, $t5, $a0             # Day*100 + Month
        addiu $t1, $zero, 10000
        mul   $t5, $t5, $t1
        addu  $a0, $t5, $a1             # N = DDMMYYYY
        addiu $a1, $zero, 8
        jal   putd

        # Bật dấu chấm: D6 (sau Ngày), D4 (sau Tháng)
        lw    $t0, D6($zero)
        ori   $t0, $t0, CHAR_DP
        sw    $t0, D6($zero)
        lw    $t0, D4($zero)
        ori   $t0, $t0, CHAR_DP
        sw    $t0, D4($zero)
        j     dr_out

# View 3: Số tuần ISO & Tên Thứ (W03  THU) -> Không cần NTP!
dt_week:
        andi  $t0, $t4, 0xffff          # t0 = days from 2000
        # dow = (days + 6) % 7
        addiu $t1, $t0, 6
        addiu $t2, $zero, 7
        div   $t1, $t2
        mfhi  $t2                       # t2 = dow (0: SUN .. 6: SAT)

        # iso_dow: if dow == 0 then 7 else dow
        addu  $t3, $t2, $zero
        bne   $t3, $zero, dw_iso
        addiu $t3, $zero, 7
dw_iso: # t3 = iso_dow (1..7, Mon=1..Sun=7)
        # d_thurs = days + (4 - iso_dow)
        addiu $t4, $zero, 4
        subu  $t4, $t4, $t3
        addu  $t4, $t0, $t4             # t4 = d_thurs

        # Lấy năm của Thursday: d2ymd(d_thurs) -> $a1 = yr_T
        addu  $a0, $t4, $zero
        jal   d2ymd
        # $a1 = yr_T (offset từ 2000)

        # Tính d0 = ngày mốc 01/01 của năm yr_T:
        # c4 = yr_T / 4
        sra   $t6, $a1, 2
        ori   $t1, $zero, 1461
        mul   $t6, $t6, $t1             # d0 = c4 * 1461
        andi  $t1, $a1, 3               # remY = yr_T % 4
        beq   $t1, $zero, dw_d0_done
        addiu $t6, $t6, 366             # d0 += 366 (năm 2000 nhuận)
        addiu $t1, $t1, -1
        ori   $t5, $zero, 365
        mul   $t1, $t1, $t5
        addu  $t6, $t6, $t1             # d0 += (remY - 1) * 365
dw_d0_done:
        # week = 1 + (d_thurs - d0) / 7
        subu  $t7, $t4, $t6             # d_thurs - d0
        addiu $t1, $zero, 7
        div   $t7, $t1
        mflo  $t7
        addiu $t7, $t7, 1               # week (1..53)

        # D7: Chữ 'W'
        addiu $t0, $zero, CHAR_W
        sw    $t0, D7($zero)

        # D6, D5: 2 chữ số tuần
        ori   $t1, $zero, 10
        div   $t7, $t1
        mflo  $t0                       # Hàng chục
        sw    $t0, D6($zero)
        mfhi  $t0                       # Hàng đơn vị
        sw    $t0, D5($zero)

        # D4, D3: 2 khoảng trắng ngăn cách
        addiu $t0, $zero, CHAR_BLANK
        sw    $t0, D4($zero)
        sw    $t0, D3($zero)

        # D2, D1, D0: 3 ký tự viết tắt ngày trong tuần (MON, TUE, WED, THU, FRI, SAT, SUN)
        lw    $t4, REG_DAY_SHADOW($zero)
        sra   $t2, $t4, 16
        andi  $t2, $t2, 7

        # 0: SUN (S, U, n -> 0x16, 0x18, 0x12)
        bne   $t2, $zero, dw_not_sun
        addiu $t0, $zero, 0x16          # 'S'
        sw    $t0, D2($zero)
        addiu $t0, $zero, 0x18          # 'U'
        sw    $t0, D1($zero)
        addiu $t0, $zero, 0x12          # 'n'
        sw    $t0, D0($zero)
        j     dr_out

dw_not_sun:
        # 1: MON (M, o, n -> 0x1B, 0x13, 0x12)
        addiu $t1, $zero, 1
        bne   $t2, $t1, dw_not_mon
        addiu $t0, $zero, CHAR_M        # 'M'
        sw    $t0, D2($zero)
        addiu $t0, $zero, 0x13          # 'o'
        sw    $t0, D1($zero)
        addiu $t0, $zero, 0x12          # 'n'
        sw    $t0, D0($zero)
        j     dr_out

dw_not_mon:
        # 2: TUE (t, U, E -> 0x17, 0x18, 0x0E)
        addiu $t1, $zero, 2
        bne   $t2, $t1, dw_not_tue
        addiu $t0, $zero, CHAR_T        # 't'
        sw    $t0, D2($zero)
        addiu $t0, $zero, 0x18          # 'U'
        sw    $t0, D1($zero)
        addiu $t0, $zero, 0x0E          # 'E'
        sw    $t0, D0($zero)
        j     dr_out

dw_not_tue:
        # 3: WED (W, E, d -> 0x1C, 0x0E, 0x0D)
        addiu $t1, $zero, 3
        bne   $t2, $t1, dw_not_wed
        addiu $t0, $zero, CHAR_W        # 'W'
        sw    $t0, D2($zero)
        addiu $t0, $zero, 0x0E          # 'E'
        sw    $t0, D1($zero)
        addiu $t0, $zero, 0x0D          # 'd'
        sw    $t0, D0($zero)
        j     dr_out

dw_not_wed:
        # 4: THU (t, H, U -> 0x17, 0x10, 0x18)
        addiu $t1, $zero, 4
        bne   $t2, $t1, dw_not_thu
        addiu $t0, $zero, CHAR_T        # 't'
        sw    $t0, D2($zero)
        addiu $t0, $zero, 0x10          # 'H'
        sw    $t0, D1($zero)
        addiu $t0, $zero, 0x18          # 'U'
        sw    $t0, D0($zero)
        j     dr_out

dw_not_thu:
        # 5: FRI (F, r, 1 -> 0x0F, 0x15, 0x01)
        addiu $t1, $zero, 5
        bne   $t2, $t1, dw_sat
        addiu $t0, $zero, 0x0F          # 'F'
        sw    $t0, D2($zero)
        addiu $t0, $zero, 0x15          # 'r'
        sw    $t0, D1($zero)
        addiu $t0, $zero, 0x01          # '1'
        sw    $t0, D0($zero)
        j     dr_out

dw_sat: # 6: SAT (S, A, t -> 0x16, 0x0A, 0x17)
        addiu $t0, $zero, 0x16          # 'S'
        sw    $t0, D2($zero)
        addiu $t0, $zero, 0x0A          # 'A'
        sw    $t0, D1($zero)
        addiu $t0, $zero, CHAR_T        # 't'
        sw    $t0, D0($zero)
        j     dr_out
