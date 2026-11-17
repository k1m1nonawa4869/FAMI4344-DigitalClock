# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP NGUỒN:      fw/isr.s — Trình Phục Vụ Ngắt Ngoại Vi (Interrupt Service Routine)
# VAI TRÒ:        Xử lý vector ngắt phần cứng tại địa chỉ cố định 0x00000180
#                 phục vụ tiếp nhận ký tự UART_RX và chụp tem thời gian
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Kiến Trúc Ngắt MIPS32 Coprocessor 0 (Patterson & Hennessy §B.7):
#      Khi có tín hiệu ngắt phần cứng kích hoạt (IRQ = 1 và Status.IE = 1):
#        + Phần cứng CPU lưu địa chỉ lệnh tiếp theo vào thanh ghi $epc ($14).
#        + Ghi mã nguyên nhân ngắt vào thanh ghi $cause ($13).
#        + Bật cờ EXL trong $status ($12) để tự động khóa các ngắt lồng nhau.
#        + Nạp con trỏ lệnh PC nhảy trực tiếp tới địa chỉ cố định 0x00000180.
#    - Lưu Ngữ Cảnh (Context Saving):
#      Trình ngắt phải bảo toàn giá trị các thanh ghi đa năng ($t0, $t1, $t2, $ra)
#      bằng cách cất vào vùng nhớ DMEM (V_IT0..V_IT2) trước khi thực thi
#      và khôi phục đầy đủ trước khi thực hiện lệnh eret (Exception Return).
# ============================================================================

        .org  0x180                     # Vector ngắt cố định tại 0x00000180
        sw    $t0, V_IT0($zero)         # Cất ngữ cảnh thanh ghi $t0
        sw    $t1, V_IT1($zero)         # Cất ngữ cảnh thanh ghi $t1
        sw    $t2, V_IT2($zero)         # Cất ngữ cảnh thanh ghi $t2
        addu  $k1, $ra, $zero           # Lưu thanh ghi $ra vào $k1 (thanh ghi đặc quyền OS)
        addiu $k0, $zero, 0x40          # Mặt nạ ngắt UART_RX (bit 6)
        sw    $k0, REG_IRQ_PENDING($zero) # Xóa cờ PENDING bit 6 (W1C) trước khi đọc byte
        jal   sy_rx                     # Gọi hàm gom byte UART trong uart_sync.s
        addu  $ra, $k1, $zero           # Khôi phục thanh ghi $ra từ $k1
        lw    $t0, V_IT0($zero)         # Khôi phục ngữ cảnh thanh ghi $t0
        lw    $t1, V_IT1($zero)         # Khôi phục ngữ cảnh thanh ghi $t1
        lw    $t2, V_IT2($zero)         # Khôi phục ngữ cảnh thanh ghi $t2
        eret                            # Trở về từ ngắt, khôi phục PC = $epc và hạ cờ EXL
