# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP ĐẦU VÀO:    fw/mmio.inc — Bảng Định Nghĩa Địa Chỉ Vào/Ra Ánh Xạ Bộ Nhớ (MMIO)
# VAI TRÒ:        Định nghĩa các hằng số địa chỉ MMIO chuẩn mực giáo trình Patterson
#                 (Patterson & Hennessy §B.8), quy chuẩn từ dải địa chỉ 0xFFFF0000.
#                 Thay thế hoàn toàn cách viết số nguyên âm quy ước cũ.
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Không Gian Địa Chỉ Ngoại Vi (Memory-Mapped I/O Address Space):
#      Toàn bộ các thanh ghi điều khiển phần cứng của SoC được ánh xạ vào dải
#      địa chỉ cao nhất của bộ nhớ 32-bit: 0xFFFF0000 .. 0xFFFFFFFF.
#      Lõi CPU sử dụng các lệnh lw (Load Word) và sw (Store Word) thông thường
#      để đọc/ghi các thanh ghi ngoại vi.
#    - Cơ chế Truy Cập 1 Lệnh (Single-Instruction Zero-Base Access):
#      Trong kiến trúc MIPS, trường immediate của lệnh lw/sw là số nguyên 16-bit
#      có dấu (-32768 .. +32767). Khi sử dụng thanh ghi cơ sở $zero ($0):
#        Offset âm trong khoảng -256 .. -1 (0xFF00 .. 0xFFFF) khi mở rộng dấu
#        32-bit sẽ tạo ra chính xác địa chỉ 0xFFFFFF00 .. 0xFFFFFFFF!
#      Do đó, định nghĩa REG_* dạng offset âm cho phép phần mềm truy xuất
#      ngoại vi trong đúng 1 lệnh (ví dụ: sw $t0, REG_SET_MS($zero)) mà không
#      tốn thêm lệnh lui/ori để nạp con trỏ cơ sở vào thanh ghi đa năng.
#
# 2. BẢNG ÁNH XẠ THANH GHI NGOẠI VI (MMIO REGISTER ADDRESS MAP):
# ============================================================================

# ----------------------------------------------------------------------------
# ĐỊA CHỈ GỐC MMIO (MMIO BASE ADDRESS)
# ----------------------------------------------------------------------------
        .eqv  MMIO_BASE         0xFFFF0000      # Địa chỉ cơ sở MMIO chuẩn 32-bit
        .eqv  MMIO_BASE_HI      0xFFFF          # 16-bit cao phục vụ lệnh lui

# ----------------------------------------------------------------------------
# 1. THANH GHI HỆ THỐNG & TẠO NHỊP (SOC REGISTERS - soc_regs.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_CYCLE_COUNT   0x00            # Offset dương: Đếm chu kỳ hệ thống 50 MHz (R)
        .eqv  OFF_CAL           0x18            # Offset dương: Bù trôi thạch anh ppm có dấu (R/W)
        .eqv  OFF_CPU_CLK_DIV   0x8C            # Offset dương: Hệ số chia xung nhịp CPU D (R/W)
        .eqv  OFF_DIV_FLAGS     0x90            # Offset dương: Cờ chia cho 0 từ muldiv (R)

        .eqv  REG_CYCLE_COUNT   -256            # Direct $zero: 0xFFFFFF00 (R)
        .eqv  REG_CAL           -232            # Direct $zero: 0xFFFFFF18 (R/W)
        .eqv  REG_CPU_CLK_DIV   -116            # Direct $zero: 0xFFFFFF8C (R/W)
        .eqv  REG_DIV_FLAGS     -112            # Direct $zero: 0xFFFFFF90 (R)

# ----------------------------------------------------------------------------
# 2. ĐỒNG HỒ THỜI GIAN THỰC (REAL-TIME CLOCK - rtc_core.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_RTC_MS        0x04            # Offset dương: ms trong ngày 0..86399999 (R)
        .eqv  OFF_DAY_SHADOW    0x08            # Offset dương: Chốt bóng {dow[2:0], day[15:0]} (R)
        .eqv  OFF_SET_MS        0x0C            # Offset dương: Giờ nạp ms chờ ARM (W)
        .eqv  OFF_SET_DAY       0x10            # Offset dương: Ngày nạp chờ ARM (W)
        .eqv  OFF_RTC_CTRL      0x14            # Offset dương: Điều khiển RTC bit 0: ARM (R/W)

        .eqv  REG_RTC_MS        -252            # Direct $zero: 0xFFFFFF04 (R)
        .eqv  REG_DAY_SHADOW    -248            # Direct $zero: 0xFFFFFF08 (R)
        .eqv  REG_SET_MS        -244            # Direct $zero: 0xFFFFFF0C (W)
        .eqv  REG_SET_DAY       -240            # Direct $zero: 0xFFFFFF10 (W)
        .eqv  REG_RTC_CTRL      -236            # Direct $zero: 0xFFFFFF14 (R/W)

        .eqv  RTC_BIT_ARM       0x01            # Bit 0 của RTC_CTRL: Chốt nạp giờ mới

# ----------------------------------------------------------------------------
# 3. BỘ BẤM GIỜ THỂ THAO (STOPWATCH CORE - stopwatch_core.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_SW_CTRL       0x1C            # Offset dương: Điều khiển Stopwatch (R/W)
        .eqv  OFF_SW_VALUE      0x20            # Offset dương: Thời gian bấm giờ hiện tại (R)
        .eqv  OFF_SW_LAP        0x24            # Offset dương: Đọc Lap từ FIFO 8 phần tử (R)

        .eqv  REG_SW_CTRL       -228            # Direct $zero: 0xFFFFFF1C (R/W)
        .eqv  REG_SW_VALUE      -224            # Direct $zero: 0xFFFFFF20 (R)
        .eqv  REG_SW_LAP        -220            # Direct $zero: 0xFFFFFF24 (R)

        .eqv  SW_BIT_EN         0x01            # Bit 0: Cho phép chạy (Enable)
        .eqv  SW_BIT_CLR        0x02            # Bit 1: Xóa về 0 (Clear)
        .eqv  SW_BIT_SRC        0x04            # Bit 2: Chọn nguồn nút phần cứng (Hardware Capture)
        .eqv  SW_BIT_OVF        0x08            # Bit 3: Cờ tràn 99:59:59.999
        .eqv  SW_BIT_LAP_READY  0x10            # Bit 4: FIFO Lap có dữ liệu

# ----------------------------------------------------------------------------
# 4. BỘ HẸN GIỜ ĐẾM LÙI (COUNTDOWN TIMER CORE - countdown_core.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_TMR_VALUE     0x28            # Offset dương: Thời gian đếm lùi bù âm (R/W)
        .eqv  OFF_TMR_CTRL      0x2C            # Offset dương: Điều khiển bộ đếm lùi (R/W)

        .eqv  REG_TMR_VALUE     -216            # Direct $zero: 0xFFFFFF28 (R/W)
        .eqv  REG_TMR_CTRL      -212            # Direct $zero: 0xFFFFFF2C (R/W)

        .eqv  TMR_BIT_EN        0x01            # Bit 0: Cho phép đếm lùi
        .eqv  TMR_BIT_CLR       0x02            # Bit 1: Xóa bộ đếm về 0
        .eqv  TMR_BIT_BEEP_EN   0x04            # Bit 2: Tự động kích còi phần cứng khi về 0
        .eqv  TMR_BIT_UNDERFLOW 0x08            # Bit 3: Cờ đếm quá giờ (âm)

# ----------------------------------------------------------------------------
# 5. BỘ ĐIỀU KHIỂN BÁO THỨC 4 KÊNH (ALARM CONTROLLER - alarm_controller.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_ALARM0        0x30            # Offset dương: Báo thức kênh 0 (R/W)
        .eqv  OFF_ALARM1        0x34            # Offset dương: Báo thức kênh 1 (R/W)
        .eqv  OFF_ALARM2        0x38            # Offset dương: Báo thức kênh 2 (R/W)
        .eqv  OFF_ALARM3        0x3C            # Offset dương: Báo thức kênh 3 (R/W)

        .eqv  REG_ALARM0        -208            # Direct $zero: 0xFFFFFF30 (R/W)
        .eqv  REG_ALARM1        -204            # Direct $zero: 0xFFFFFF34 (R/W)
        .eqv  REG_ALARM2        -200            # Direct $zero: 0xFFFFFF38 (R/W)
        .eqv  REG_ALARM3        -196            # Direct $zero: 0xFFFFFF3C (R/W)

# ----------------------------------------------------------------------------
# 6. BỘ ĐIỀU KHIỂN NGẮT 8 NGUỒN (INTERRUPT CONTROLLER - irq_ctrl.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_IRQ_ENABLE    0x44            # Offset dương: Mặt nạ cho phép ngắt 8-bit (R/W)
        .eqv  OFF_IRQ_PENDING   0x48            # Offset dương: Cờ ngắt đang chờ W1C (R/W)
        .eqv  OFF_IRQ_STAMP     0x4C            # Offset dương: Tem chu kỳ xuất hiện ngắt (R)

        .eqv  REG_IRQ_ENABLE    -188            # Direct $zero: 0xFFFFFF44 (R/W)
        .eqv  REG_IRQ_PENDING   -184            # Direct $zero: 0xFFFFFF48 (R/W)
        .eqv  REG_IRQ_STAMP     -180            # Direct $zero: 0xFFFFFF4C (R)

        .eqv  IRQ_BIT_TICK_1MS  0x01            # Bit 0: Ngắt nhịp 1 ms từ timebase
        .eqv  IRQ_BIT_TICK_1S   0x02            # Bit 1: Ngắt nhịp 1 s từ rtc_core
        .eqv  IRQ_BIT_TMR_ZERO  0x04            # Bit 2: Ngắt đếm lùi về 0
        .eqv  IRQ_BIT_ALARM     0x08            # Bit 3: Ngắt báo thức trùng khớp
        .eqv  IRQ_BIT_SW_CAP    0x10            # Bit 4: Ngắt chụp Lap bấm giờ
        .eqv  IRQ_BIT_BTN       0x20            # Bit 5: Ngắt có sự kiện nút bấm mới
        .eqv  IRQ_BIT_UART_RX   0x40            # Bit 6: Ngắt nhận ký tự UART mới
        .eqv  IRQ_BIT_UART_TX   0x80            # Bit 7: Ngắt đệm phát UART trống

# ----------------------------------------------------------------------------
# 7. BÀN PHÍM NÚT BẤM KHỬ RUNG (BUTTONS CONTROLLER - buttons.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_BTN_EVENT     0x40            # Offset dương: Đọc sự kiện nút từ FIFO 4 phần tử (R)
        .eqv  REG_BTN_EVENT     -192            # Direct $zero: 0xFFFFFF40 (R)

# ----------------------------------------------------------------------------
# 8. TRUYỀN THÔNG NỐI TIẾP UART 115200 8N1 (UART CONTROLLER - uart.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_UART_STATUS   0x50            # Offset dương: Cờ trạng thái & lỗi W1C (R/W)
        .eqv  OFF_UART_RX       0x54            # Offset dương: Đọc byte từ RX FIFO (R)
        .eqv  OFF_UART_TX       0x58            # Offset dương: Ghi byte ra TX buffer (W)

        .eqv  REG_UART_STATUS   -176            # Direct $zero: 0xFFFFFF50 (R/W)
        .eqv  REG_UART_RX       -172            # Direct $zero: 0xFFFFFF54 (R)
        .eqv  REG_UART_TX       -168            # Direct $zero: 0xFFFFFF58 (W)

        .eqv  UART_BIT_RX_READY 0x01            # Bit 0: RX FIFO có byte chờ đọc
        .eqv  UART_BIT_TX_EMPTY 0x02            # Bit 1: TX buffer trống, sẵn sàng gửi
        .eqv  UART_BIT_TX_BUSY  0x04            # Bit 2: TX đang truyền bit ra chân phát
        .eqv  UART_BIT_RX_OVF   0x08            # Bit 3: Lỗi tràn bộ đệm RX FIFO (W1C)
        .eqv  UART_BIT_FRAME    0x10            # Bit 4: Lỗi khung truyền stop-bit (W1C)
        .eqv  UART_BIT_TX_DROP  0x20            # Bit 5: Lỗi ghi đè khi TX bận (W1C)

# ----------------------------------------------------------------------------
# 9. BỘ ĐIỀU KHIỂN QUÉT HIỂN THỊ LED 7 ĐOẠN (DISPLAY CONTROLLER - display_ctrl.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_DISP0         0x5C            # Offset dương: Ô LED 0 (ngoài cùng bên phải)
        .eqv  OFF_DISP1         0x60            # Offset dương: Ô LED 1
        .eqv  OFF_DISP2         0x64            # Offset dương: Ô LED 2
        .eqv  OFF_DISP3         0x68            # Offset dương: Ô LED 3
        .eqv  OFF_DISP4         0x6C            # Offset dương: Ô LED 4
        .eqv  OFF_DISP5         0x70            # Offset dương: Ô LED 5
        .eqv  OFF_DISP6         0x74            # Offset dương: Ô LED 6
        .eqv  OFF_DISP7         0x78            # Offset dương: Ô LED 7 (ngoài cùng bên trái)
        .eqv  OFF_BLINK_MASK    0x7C            # Offset dương: Mặt nạ nhấp nháy 8-bit (W)
        .eqv  OFF_BRIGHT        0x80            # Offset dương: Độ sáng LED 4-bit PWM 0..15 (W)

        .eqv  REG_DISP0         -164            # Direct $zero: 0xFFFFFF5C (W)
        .eqv  REG_DISP1         -160            # Direct $zero: 0xFFFFFF60 (W)
        .eqv  REG_DISP2         -156            # Direct $zero: 0xFFFFFF64 (W)
        .eqv  REG_DISP3         -152            # Direct $zero: 0xFFFFFF68 (W)
        .eqv  REG_DISP4         -148            # Direct $zero: 0xFFFFFF6C (W)
        .eqv  REG_DISP5         -144            # Direct $zero: 0xFFFFFF70 (W)
        .eqv  REG_DISP6         -140            # Direct $zero: 0xFFFFFF74 (W)
        .eqv  REG_DISP7         -136            # Direct $zero: 0xFFFFFF78 (W)
        .eqv  REG_BLINK_MASK    -132            # Direct $zero: 0xFFFFFF7C (W)
        .eqv  REG_BRIGHT        -128            # Direct $zero: 0xFFFFFF80 (W)

# ----------------------------------------------------------------------------
# 10. BỘ ĐIỀU CHẾ ÂM THANH CÒI BUZZER (PWM BEEPER - beeper.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_BEEP_FREQ     0x84            # Offset dương: Tần số chu kỳ vuông (W)
        .eqv  OFF_BEEP_PATTERN  0x88            # Offset dương: Chuỗi giai điệu 16 khe 64ms (W)

        .eqv  REG_BEEP_FREQ     -124            # Direct $zero: 0xFFFFFF84 (W)
        .eqv  REG_BEEP_PAT      -120            # Direct $zero: 0xFFFFFF88 (W)

        .eqv  BEEP_PAT_ALARM    0x10F0F         # Mẫu giai điệu báo thức ngắt quãng dồn dập
        .eqv  BEEP_PAT_BTN      0x10001         # Tiếng bíp ngắn phản hồi nhấn nút 64ms
        .eqv  BEEP_PAT_CHIME    0x10003         # Tiếng bíp kép báo chuyển canh giờ

# ----------------------------------------------------------------------------
# 11. BỘ TĂNG TỐC BCD PHẦN CỨNG TÙY CHỌN (OPTIONAL HARDWARE BCD - rtc_bcd.v)
# ----------------------------------------------------------------------------
        .eqv  OFF_RTC_BCD       0x98            # Offset dương: Đọc trực tiếp BCD từ RTC (R/W)
        .eqv  REG_RTC_BCD       -104            # Direct $zero: 0xFFFFFF98 (R/W)
