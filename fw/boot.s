# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/boot.s — Khởi Tạo Hệ Thống & Nạp Cấu Hình Ban Đầu (Bootloader)
# VAI TRÒ:        Khởi tạo giá trị RTC, cấu hình bộ đếm lùi, thiết lập 4 kênh
#                 báo thức, cấu hình độ sáng LED và bật ngắt hệ thống
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Quy Trình Khởi Động Vi Điều Khiển (Embedded System Boot Sequence):
#      Sau tín hiệu Reset phần cứng, CPU bắt đầu thực thi từ địa chỉ 0x00000000.
#      Lệnh đầu tiên nhảy qua vùng vector ngắt 0x180 để tới nhãn boot:.
#    - Nạp Thời Gian Thực An Toàn (Safe RTC 2-Phase Arming):
#      Đọc cấu hình kiểm thử tại CFG_MAG (0x7E0). Nếu hợp lệ, ghi giờ vào
#      REG_SET_MS và REG_SET_DAY, sau đó bật cờ ARM trong REG_RTC_CTRL và
#      chờ đồng bộ sườn 1 ms để nạp giờ mới mà không bị đứt đoạn.
# ============================================================================

boot:   lw    $t0, CFG_MAG($zero)       # Kiểm tra từ ma thuật kiểm thử (POST magic)
        beq   $t0, $zero, b_def
        lw    $t0, CFG_MS($zero)        # Nạp giờ định sẵn từ cấu hình
        sw    $t0, REG_SET_MS($zero)    # Ghi vào thanh ghi SET_MS
        lw    $t0, CFG_DAY($zero)       # Nạp ngày định sẵn từ cấu hình
        sw    $t0, REG_SET_DAY($zero)   # Ghi vào thanh ghi SET_DAY
        addiu $t0, $zero, RTC_BIT_ARM
        sw    $t0, REG_RTC_CTRL($zero)  # Kích hoạt chốt nạp giờ (ARM = 1)
b_wait: lw    $t0, REG_RTC_CTRL($zero)
        bne   $t0, $zero, b_wait        # Chờ phần cứng hoàn tất nạp giờ (ARM tự về 0)
        lw    $t0, CFG_PRE($zero)       # Nạp giá trị đặt trước cho Timer
        j     b_pre
b_def:  ori   $t0, $zero, 60000         # Giá trị mặc định cho Timer: 60.000 ms (01:00.000)
b_pre:  sw    $t0, V_PRE($zero)         # Lưu vào biến DMEM
        sw    $t0, REG_TMR_VALUE($zero) # Cài đặt giá trị bộ đếm lùi phần cứng
        sw    $t0, V_TMR_SNAP($zero)    # Khởi tạo snapshot với mốc timer ban đầu
        sw    $zero, V_TPAUSED($zero)   # Xóa cờ tạm dừng
        sw    $zero, V_SW_MODE($zero)   # Mặc định chế độ Stopwatch 9 Laps @ 1 ms
        sw    $zero, V_SW_GAP($zero)    # Mặc định hiển thị SPLIT mốc thời gian tuyệt đối
        sw    $zero, V_TMR_SUBMODE($zero) # Mặc định chế độ đếm lùi Đơn (Single Timer)
        sw    $zero, V_CHESS_ACT($zero) # Trạng thái cờ vua mặc định: Dừng/Chờ
        lui   $t0, 4
        ori   $t0, $t0, 0x93e0          # 300.000 ms = 5 phút cờ chớp FIDE Blitz
        sw    $t0, V_CHESS_INIT($zero)
        sw    $t0, V_CHESS_L($zero)
        sw    $t0, V_CHESS_R_INIT($zero)
        sw    $t0, V_CHESS_R($zero)
        sw    $zero, V_B_CNT($zero)     # Khởi tạo bộ đếm bấm nhanh phím B = 0
        sw    $zero, V_B_LAST($zero)
        ori   $t0, $zero, 60000         # Thời lượng chuông mặc định: 60 giây (khớp system_tb.v sys_5)
        sw    $t0, V_ALM_DUR($zero)
        sw    $zero, V_TICK_INT($zero)  # Tắt tiếng tick định kỳ khi boot
        addiu $t0, $zero, 1             # Số tiếng bíp tick mặc định: 1
        sw    $t0, V_TICK_CNT($zero)
        sw    $zero, V_TMR_STP0($zero)  # Mặc định chế độ Overtime (khớp system_tb.v sys_4)
        addiu $t0, $zero, TMR_BIT_BEEP_EN
        sw    $t0, REG_TMR_CTRL($zero)  # Cho phép tự kích còi khi đếm về 0
        lui   $t0, 0x3e00               # Báo thức 1: 07:00 (420 phút), T2 -> T6, tắt
        ori   $t0, $t0, 420
        sw    $t0, REG_ALARM0($zero)
        lui   $t0, 0x7f00               # Báo thức 2..4: 00:00, mọi ngày, tắt
        sw    $t0, REG_ALARM1($zero)
        sw    $t0, REG_ALARM2($zero)
        sw    $t0, REG_ALARM3($zero)
        addiu $t0, $zero, -1            # Đặt giờ trước đó = -1 (chống kêu chuông giờ sai khi boot)
        sw    $t0, V_LASTH($zero)
        addiu $t0, $zero, 15            # Cài đặt độ sáng LED mặc định cực đại (15/15)
        sw    $t0, V_BRI($zero)
        addiu $t0, $zero, USE_IRQ
        sll   $t0, $t0, 6               # Mặt nạ ngắt UART_RX (bit 6 = 0x40)
        sw    $t0, REG_IRQ_ENABLE($zero) # Cho phép ngắt UART_RX trong irq_ctrl
