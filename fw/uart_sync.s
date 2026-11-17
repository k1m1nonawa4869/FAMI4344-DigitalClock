# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/uart_sync.s — Giao Thức Đồng Bộ Thời Gian & Bù Trôi CAL (UART NTP)
# VAI TRÒ:        Tiếp nhận và giải mã khung bản tin đồng bộ thời gian từ máy tính
#                 qua cổng nối tiếp UART 115200 8N1, tính toán kiểm tra checksum,
#                 tự động điều chỉnh hệ số bù trôi thạch anh CAL (ppm).
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Giao Thức Khung Bản Tin NMEA/NTP ($Q, $R, $T, $Z):
#        + "$Q*51\n": Máy tính hỏi thời gian hiện tại -> SoC phản hồi "$R,<ms>,<day>*CS\n".
#        + "$T,<ms>,<day>*CS\n": Máy tính gửi mốc thời gian chuẩn để nạp giờ và tính CAL.
#        + "$Z,<ms>,<day>*CS\n": SoC tự động gửi thông báo khi đếm lùi về 0.
#      Checksum (CS) là phép XOR bitwise của mọi ký tự nằm giữa '$' và '*'.
#    - Thuật Toán Bù Sai Lệch Thạch Anh Từng Phần Triệu (Crystal PPM Calibration):
#      Khi nhận 2 mốc đồng bộ cách nhau khoảng thời gian I (ms) với sai lệch trôi D (ms):
#        ΔCAL = ((D × 65536) / (I / 1000)) × 50
#      Giá trị CAL mới được cộng dồn vào thanh ghi REG_CAL và giới hạn trong
#      khoảng an toàn ±200 ppm (|CAL| ≤ 655.360).
#    - Cơ Chế Bộ Đệm Đôi (Double Buffering Architecture):
#      Sử dụng bộ đệm nhận V_RBUF (thu thập trong ngắt) và bộ đệm xử lý V_SBUF
#      (xử lý trong vòng lặp chính). Điều này đảm bảo khi bản tin thứ 2 đến
#      ngay sát bản tin thứ 1 thì tem thời gian chốt lúc gặp '\n' vẫn chuẩn xác.
# ============================================================================

# ----------------------------------------------------------------------------
# 1. TIẾN TRÌNH THU THẬP KÝ TỰ UART TỪ PHẦN CỨNG (UART RX HARVESTER)
# ----------------------------------------------------------------------------
sy_rx:  lw    $t0, V_RRDY($zero)
        beq   $t0, $zero, rx1
        lw    $t0, V_SRDY($zero)
        bne   $t0, $zero, rx_r          # Câu trước chưa xử lý xong, bộ đệm nhận đã đầy
        lw    $t2, V_RLEN($zero)        # Chuyển dữ liệu từ bộ đệm nhận sang bộ đệm xử lý
        sw    $t2, V_SLEN($zero)
        slti  $t1, $t2, 33
        bne   $t1, $zero, rx_c
        addu  $t2, $zero, $zero         # Câu quá dài: Hủy bỏ
rx_c:   beq   $t2, $zero, rx_c2
        addiu $t2, $t2, -1
        sll   $t1, $t2, 2
        lw    $t0, V_RBUF($t1)
        sw    $t0, V_SBUF($t1)
        j     rx_c
rx_c2:  lw    $t0, V_RQMS($zero)
        sw    $t0, V_SQMS($zero)
        lw    $t0, V_RQDY($zero)
        sw    $t0, V_SQDY($zero)
        sw    $zero, V_RLEN($zero)
        sw    $zero, V_RRDY($zero)
        addiu $t0, $zero, 1
        sw    $t0, V_SRDY($zero)        # Đánh dấu bộ đệm xử lý sẵn sàng
rx1:    lw    $t0, REG_UART_RX($zero)   # Đọc byte từ thanh ghi UART_RX: [31] VALID, [7:0] data
        slt   $t1, $t0, $zero
        beq   $t1, $zero, rx_r          # FIFO rỗng (VALID = 0)
        andi  $t0, $t0, 0xff
        addiu $t1, $zero, 10            # Ký tự xuống dòng '\n' (mã ASCII 10)
        beq   $t0, $t1, rx_nl
        lw    $t2, V_RLEN($zero)
        slti  $t1, $t2, 32
        bne   $t1, $zero, rx2
        addiu $t2, $zero, 33            # Đánh dấu câu hỏng nếu dài quá 32 byte
        sw    $t2, V_RLEN($zero)
        j     rx1
rx2:    sll   $t1, $t2, 2
        sw    $t0, V_RBUF($t1)
        addiu $t2, $t2, 1
        sw    $t2, V_RLEN($zero)
        j     rx1
rx_nl:  lw    $t0, REG_RTC_MS($zero)    # Gặp '\n': Chụp ngay lập tức MS_OF_DAY và DAY_SHADOW
        sw    $t0, V_RQMS($zero)
        lw    $t0, REG_DAY_SHADOW($zero)
        sw    $t0, V_RQDY($zero)
        addiu $t0, $zero, 1
        sw    $t0, V_RRDY($zero)        # Đánh dấu đã nhận đủ 1 câu hoàn chỉnh
        j     sy_rx
rx_r:   jr    $ra

# ----------------------------------------------------------------------------
# 2. BỘ GIẢI MÃ VÀ ĐIỀU HỢP ĐỒNG BỘ THỜI GIAN (SYNC PARSER & CALIBRATOR)
# ----------------------------------------------------------------------------
sync:   addu  $s3, $ra, $zero
sy1:    mtc0  $zero, $12                # Tắt ngắt để vét sạch các byte trong FIFO
        jal   sy_rx
        addiu $t0, $zero, USE_IRQ
        mtc0  $t0, $12                  # Khôi phục ngắt
        lw    $t0, V_SRDY($zero)
        bne   $t0, $zero, sy_nl         # Có câu mới sẵn sàng xử lý
        jr    $s3                       # Không có câu: Trở về vòng lặp chính

sy_nl:  lw    $t9, V_SLEN($zero)        # Kiểm tra khuôn dạng câu: 5 <= độ dài <= 32
        slti  $t1, $t9, 33
        beq   $t1, $zero, sy_done
        slti  $t1, $t9, 5
        bne   $t1, $zero, sy_done
        lw    $t0, V_SBUF($zero)
        addiu $t1, $zero, 0x24          # Ký tự bắt đầu bắt buộc phải là '$' (0x24)
        bne   $t0, $t1, sy_done
        sll   $t9, $t9, 2
        addiu $t2, $zero, 4
        addu  $t3, $zero, $zero         # Khởi tạo giá trị XOR Checksum = 0
sc1:    beq   $t2, $t9, sy_done         # Hết câu mà không thấy '*'
        lw    $t0, V_SBUF($t2)
        addiu $t1, $zero, 0x2a          # Ký tự '*' (0x2A)
        beq   $t0, $t1, sc2
        xor   $t3, $t3, $t0             # Tính XOR tích lũy
        addiu $t2, $t2, 4
        j     sc1
sc2:    addiu $t1, $t2, 12              # '*' cộng thêm 2 ký tự hex là kết thúc câu
        bne   $t1, $t9, sy_done
        lw    $a0, V_SBUF1($t2)
        jal   hexv
        slt   $t1, $v0, $zero
        bne   $t1, $zero, sy_done
        sll   $t4, $v0, 4
        lw    $a0, V_SBUF2($t2)
        jal   hexv
        slt   $t1, $v0, $zero
        bne   $t1, $zero, sy_done
        or    $t4, $t4, $v0
        bne   $t4, $t3, sy_done         # Lỗi Checksum: Bỏ qua câu trong im lặng

        lw    $t0, V_SBUF1($zero)       # Kiểm tra mã lệnh: 'Q' hay 'T'
        addiu $t1, $zero, 0x51          # 'Q' (Query)
        bne   $t0, $t1, sy_t
        addiu $t1, $zero, 8
        bne   $t2, $t1, sy_done
        addiu $a0, $zero, 0x52          # Phản hồi lệnh 'R' (Response)
        lw    $a1, V_SQMS($zero)
        lw    $a2, V_SQDY($zero)
        jal   sy_send
        j     sy_done

sy_t:   addiu $t1, $zero, 0x54          # 'T' (Time Setting)
        bne   $t0, $t1, sy_done
        lw    $t0, V_SBUF2($zero)
        addiu $t1, $zero, 0x2c          # Dấu phẩy ','
        bne   $t0, $t1, sy_done
        addiu $a0, $zero, 12            # Bắt đầu đọc số ms từ byte thứ 3
        jal   sy_num
        lw    $t0, V_SBUF($a0)
        addiu $t1, $zero, 0x2c          # Dấu phẩy phân cách giữa ms và ngày
        bne   $t0, $t1, sy_done
        addu  $a2, $v0, $zero           # $a2 = ms chuẩn từ máy tính
        addiu $a0, $a0, 4
        jal   sy_num
        bne   $a0, $t2, sy_done         # Số ngày phải kết thúc đúng tại ký tự '*'
        addu  $a3, $v0, $zero           # $a3 = ngày chuẩn từ máy tính
        lui   $t5, 0x0526
        ori   $t5, $t5, 0x5c00          # 86.400.000 ms
        slt   $t1, $a2, $t5
        beq   $t1, $zero, sy_done
        lui   $t1, 1
        slt   $t1, $a3, $t1
        beq   $t1, $zero, sy_done

        # Tính toán sai lệch CAL nếu đã có mốc đồng bộ trước đó T1
        lw    $t0, V_T1OK($zero)
        beq   $t0, $zero, sy_set
        lw    $t0, V_T1DY($zero)
        subu  $t0, $a3, $t0             # Hiệu số ngày I
        andi  $t0, $t0, 0xffff
        slti  $t1, $t0, 2
        beq   $t1, $zero, sy_set
        mul   $t6, $t0, $t5
        addu  $t6, $t6, $a2
        lw    $t0, V_T1MS($zero)
        subu  $t6, $t6, $t0             # $t6 = Khoảng cách giữa 2 lần đồng bộ I (ms)
        slt   $t0, $t6, $zero
        bne   $t0, $zero, sy_set
        slt   $t0, $t5, $t6
        bne   $t0, $zero, sy_set

        lw    $t0, V_SQDY($zero)
        subu  $t0, $t0, $a3             # Sai lệch ngày D
        andi  $t0, $t0, 0xffff
        lw    $t7, V_SQMS($zero)
        subu  $t7, $t7, $a2             # Sai lệch ms D
        beq   $t0, $zero, sd2
        addiu $t1, $zero, 1
        bne   $t0, $t1, sd1
        addu  $t7, $t7, $t5
        j     sd2
sd1:    ori   $t1, $zero, 0xffff
        bne   $t0, $t1, sy_set
        subu  $t7, $t7, $t5
sd2:    lui   $t1, 0x9
        ori   $t1, $t1, 0x27c0          # 600.000 ms = 10 phút
        slt   $t0, $t6, $t1
        beq   $t0, $zero, sd5
        addu  $t8, $t7, $zero
        slt   $t0, $t7, $zero
        beq   $t0, $zero, sd4
        subu  $t8, $zero, $t7
sd4:    slti  $t0, $t8, 121             # I < 10 phút: |D| <= 120 ms thì giữ T1 và cộng dồn D
        beq   $t0, $zero, sy_set
        lw    $t0, V_DACC($zero)
        addu  $t0, $t0, $t7
        sw    $t0, V_DACC($zero)
        j     sy_rs

sd5:    lw    $t0, V_DACC($zero)
        addu  $t7, $t7, $t0             # Tổng sai lệch trôi D
        ori   $t1, $zero, 5000
        div   $t6, $t1
        mflo  $t1
        addu  $t8, $t7, $zero
        slt   $t0, $t7, $zero
        beq   $t0, $zero, sd3
        subu  $t8, $zero, $t7
sd3:    slt   $t0, $t1, $t8
        bne   $t0, $zero, sy_set
        sll   $t7, $t7, 16              # ΔCAL = ((D * 65536) / (I / 1000)) * 50
        ori   $t1, $zero, 1000
        div   $t6, $t1
        mflo  $t1
        div   $t7, $t1
        mflo  $t7
        addiu $t1, $zero, 50
        mul   $t7, $t7, $t1
        lw    $t0, REG_CAL($zero)       # Đọc giá trị CAL hiện tại
        addu  $t0, $t0, $t7             # Cộng dồn hệ số bù trôi mới
        lui   $t1, 0xa                  # Giới hạn cực đại 655.360 (+200 ppm)
        slt   $t7, $t1, $t0
        beq   $t7, $zero, sc3
        addu  $t0, $t1, $zero
sc3:    subu  $t1, $zero, $t1           # Giới hạn cực tiểu -655.360 (-200 ppm)
        slt   $t7, $t0, $t1
        beq   $t7, $zero, sc4
        addu  $t0, $t1, $zero
sc4:    sw    $t0, REG_CAL($zero)       # Cập nhật thanh ghi CAL phần cứng

sy_set: sw    $a2, V_T1MS($zero)        # Mốc đồng bộ T2 trở thành T1 của lần sau
        sw    $a3, V_T1DY($zero)
        addiu $t0, $zero, 1
        sw    $t0, V_T1OK($zero)
        sw    $zero, V_DACC($zero)
sy_rs:  addu  $a0, $a2, $zero
        addu  $a1, $a3, $zero
        jal   rtcset                    # Nạp giờ chuẩn vào phần cứng RTC
sy_done: sw   $zero, V_SLEN($zero)
        sw    $zero, V_SRDY($zero)      # Giải phóng bộ đệm xử lý
        j     sy1

# ----------------------------------------------------------------------------
# 3. CÁC HÀM TIỆN ÍCH CHUYỂN ĐỔI CHUỖI & PHÁT UART (UART HELPERS)
# ----------------------------------------------------------------------------
# sy_num: Chuyển đổi chuỗi ký tự ASCII sang số nguyên 32-bit
sy_num: addu  $v0, $zero, $zero
        addu  $v1, $zero, $zero
sn1:    lw    $t0, V_SBUF($a0)
        addiu $t0, $t0, -48             # Trừ mã '0' (ASCII 48)
        slt   $t1, $t0, $zero
        bne   $t1, $zero, sn2
        slti  $t1, $t0, 10
        beq   $t1, $zero, sn2
        addiu $t1, $zero, 10
        mul   $v0, $v0, $t1             # v0 = v0 * 10 + digit
        addu  $v0, $v0, $t0
        addiu $v1, $v1, 1
        addiu $a0, $a0, 4
        j     sn1
sn2:    beq   $v1, $zero, sy_done
        slti  $t1, $v1, 10
        beq   $t1, $zero, sy_done
        jr    $ra

# hexv: Chuyển ký tự hex hoa sang giá trị 0..15 (-1 nếu không hợp lệ)
hexv:   addiu $v0, $a0, -48
        slti  $t0, $v0, 10
        beq   $t0, $zero, hx1
        slt   $t0, $v0, $zero
        beq   $t0, $zero, hx_r
        j     hx_bad
hx1:    addiu $v0, $a0, -55             # 'A' (65) -> 10
        slti  $t0, $v0, 10
        bne   $t0, $zero, hx_bad
        slti  $t0, $v0, 16
        bne   $t0, $zero, hx_r
hx_bad: addiu $v0, $zero, -1
hx_r:   jr    $ra

# sy_send: Phát bản tin "$<a0>,<a1>,<a2>*CS\n" qua UART
sy_send: addu $s2, $ra, $zero
        addu  $t4, $a0, $zero
        addiu $a0, $zero, 0x24          # '$'
        jal   putc
        addu  $v1, $zero, $zero         # Checksum bắt đầu tính sau '$'
        addu  $a0, $t4, $zero
        jal   putc
        addiu $a0, $zero, 0x2c          # ','
        jal   putc
        jal   putn                      # Phát số ms
        addiu $a0, $zero, 0x2c          # ','
        jal   putc
        andi  $a1, $a2, 0xffff
        jal   putn                      # Phát số ngày
        addu  $t4, $v1, $zero
        addiu $a0, $zero, 0x2a          # '*'
        jal   putc
        sra   $a0, $t4, 4
        jal   hexc                      # Phát ký tự hex cao của Checksum
        andi  $a0, $t4, 0xf
        jal   hexc                      # Phát ký tự hex thấp của Checksum
        addiu $a0, $zero, 10            # '\n'
        jal   putc
        jr    $s2

# putn: Phát số thập phân qua UART, bỏ qua các số 0 ở đầu
putn:   addu  $t7, $ra, $zero
        bcd   $t1, $a1                  # Chuyển đổi sang BCD 8 chữ số
        addiu $t2, $zero, 8
        addu  $t3, $zero, $zero
pn1:    sra   $a0, $t1, 28
        andi  $a0, $a0, 0xf
        sll   $t1, $t1, 4
        addiu $t2, $t2, -1
        or    $t3, $t3, $a0
        bne   $t3, $zero, pn2
        bne   $t2, $zero, pn1           # Bỏ các số 0 vô nghĩa ở đầu
pn2:    addiu $a0, $a0, 48              # Cộng mã '0' để thành ký tự ASCII
        jal   putc
        bne   $t2, $zero, pn1
        jr    $t7

# hexc: Chuyển 4-bit nibble sang ký tự ASCII hex và phát
hexc:   slti  $t0, $a0, 10
        bne   $t0, $zero, hc1
        addiu $a0, $a0, 7               # 'A' - '9' - 1 = 7
hc1:    addiu $a0, $a0, 48
        j     putc

# putc: Chờ cờ TX_READY của UART và gửi byte ra ngoại vi
putc:   lw    $t0, REG_UART_STATUS($zero)
        andi  $t0, $t0, UART_BIT_TX_BUSY
        beq   $t0, $zero, putc          # Chờ tới khi bộ phát sẵn sàng
        sw    $a0, REG_UART_TX($zero)   # Ghi byte ra phần cứng UART
        xor   $v1, $v1, $a0             # Tính Checksum tích lũy
        jr    $ra
