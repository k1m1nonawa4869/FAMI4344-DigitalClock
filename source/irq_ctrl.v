// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     irq_ctrl.v — Bộ Điều Khiển Ngắt Ưu Tiên & Ghi Xóa W1C (IRQ Controller)
// CHUYÊN ĐỀ KTMT: Chương 06: Cơ Chế Ngắt & Ngoại Lệ Trong Kiến Trúc Máy Tính
// VAI TRÒ:        Khối Quản Lý Ngắt Tập Trung & Ghi Dấu Thời Điểm Ngắt (Timestamping)
// MÔ TẢ:          Module quản lý 8 nguồn ngắt ngoại vi trong hệ thống SoC:
//                 - Hỗ trợ thanh ghi mặt nạ ngắt IRQ_ENABLE.
//                 - Hỗ trợ thanh ghi trạng thái IRQ_PENDING với cơ chế Ghi 1 để Xóa (W1C).
//                 - Cơ chế ưu tiên sự kiện: Nếu xóa và phát sinh cùng chu kỳ, sự kiện mới thắng.
//                 - Tự động chốt dấu thời điểm chu kỳ xung nhịp (CYCLE_COUNT) khi phát ngắt
//                   để đo đạc độ trễ phục vụ phân tích hiệu năng hệ thống.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Phân bổ 8 kênh ngắt ngoại vi (8 Peripheral Interrupt Sources):
//    - Bit 0: TICK_1MS       — Ngắt định thời cơ sở 1 ms (từ khối timebase)
//    - Bit 1: TICK_1S        — Ngắt định thời chu kỳ 1 giây (từ khối rtc_core)
//    - Bit 2: TMR_ZERO       — Ngắt sự kiện đếm ngược chạm 0 (từ khối countdown_core)
//    - Bit 3: ALARM          — Ngắt sự kiện báo thức trùng khớp (từ khối alarm_controller)
//    - Bit 4: SW_CAPTURE     — Ngắt sự kiện chốt lap bằng nút bấm cứng (từ stopwatch_core)
//    - Bit 5: BTN            — Ngắt sự kiện có phím mới vào hàng đợi (từ khối buttons)
//    - Bit 6: UART_RX        — Ngắt nhận ký tự UART mới (từ khối uart)
//    - Bit 7: UART_TX_EMPTY  — Ngắt bộ đệm phát UART sẵn sàng (từ khối uart)
//
// 2. Cơ chế Che Mặt Nạ Ngắt & Tổng Hợp Đường Ngắt (Interrupt Masking & Priority):
//    - Thanh ghi `enable` (8-bit) cho phép CPU lựa chọn các nguồn ngắt được phép phục vụ.
//    - Thanh ghi `pending` (8-bit) lưu vết các sự kiện ngắt đã xuất hiện (kể cả khi bị che).
//    - Tín hiệu ngắt hợp lệ gửi đến thanh ghi Cause.IP của CPU:
//          ip  = pending & enable;
//    - Đường ngắt mức tổng hợp gửi tới CPU:
//          irq = |ip;  (mức 1 nếu có ít nhất 1 nguồn ngắt vừa pending vừa enable).
//
// 3. Cơ chế Xóa Ngắt Ghi 1 Xóa (Write-1-to-Clear - W1C):
//    - Vấn đề của cơ chế Read-Modify-Write truyền thống: Nếu CPU đọc pending, sau đó tính toán
//      và ghi đè lại để xóa cờ, một ngắt mới xuất hiện giữa chu kỳ đọc và ghi sẽ bị xóa oan.
//    - Giải pháp W1C: CPU chỉ cần ghi trực tiếp byte có bit 1 tại vị trí muốn xóa:
//          `clr = (bus_we && bus_addr == A_PEND) ? bus_wdata[7:0] : 8'd0;`
//    - Xử lý xung đột cùng chu kỳ:
//          `pending <= (pending & ~clr) | ev;`
//      Phép toán `| ev` đảm bảo nếu sự kiện ngắt mới xuất hiện đúng chu kỳ CPU ghi lệnh xóa,
//      sự kiện mới luôn chiến thắng (không bao giờ làm thất thoát ngắt).
//
// 4. Cơ chế Ghi Dấu Thời Điểm Ngắt (Interrupt Latency Timestamping):
//    - Khi tín hiệu `irq` chuyển mức từ 0 lên 1 lần đầu tiên (`irq && !irq_q`), phần cứng
//      chụp tức thời giá trị bộ đếm chu kỳ `cycle_count` vào thanh ghi `stamp`.
//    - Firmware trong trình phục vụ ngắt (ISR) đọc thanh ghi `A_STAMP` để so sánh với
//      thời điểm hiện tại, từ đó tính toán chính xác độ trễ vào ngắt (Interrupt Latency)
//      phục vụ thí nghiệm kiến trúc máy tính.
// ============================================================================

`timescale 1ns/1ps

module irq_ctrl (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,             // Xung nhịp hệ thống 50 MHz
    input  wire        rst,             // Reset đồng bộ mức cao (Active-high Reset)
    input  wire [7:0]  ev,              // 8 xung sự kiện ngắt từ các khối ngoại vi (1 chu kỳ)
    input  wire [31:0] cycle_count,     // Bộ đếm chu kỳ toàn hệ thống từ CPU/SoC
    
    // Giao diện Bus MMIO
    input  wire [7:0]  bus_addr,        // Địa chỉ thanh ghi ngoại vi
    input  wire [31:0] bus_wdata,       // Dữ liệu ghi từ CPU
    input  wire        bus_we,          // Tín hiệu ghi MMIO
    input  wire        bus_re,          // Tín hiệu đọc MMIO
    output reg  [31:0] bus_rdata,       // Dữ liệu đọc trả về cho CPU
    
    // Tín hiệu ngắt xuất sang CPU
    output wire        irq,             // Mức tích cực báo ngắt gửi tới lõi CPU MIPS
    output wire [7:0]  ip               // Các bit ngắt đang chờ đã được unmask (kết nối Cause.IP)
);

    // ------------------------------------------------------------------------
    // ĐỊA CHỈ THANH GHI NGOẠI VI (MMIO REGISTER ADDRESS MAP)
    // ------------------------------------------------------------------------
    localparam A_EN    = 8'h44,         // 0x44: Thanh ghi mặt nạ ngắt IRQ_ENABLE (R/W)
               A_PEND  = 8'h48,         // 0x48: Thanh ghi cờ ngắt IRQ_PENDING (R/W1C - Ghi 1 để xóa)
               A_STAMP = 8'h4C;         // 0x4C: Thanh ghi dấu thời điểm chu kỳ ngắt IRQ_STAMP (Read-Only)

    // ------------------------------------------------------------------------
    // THANH GHI VÀ TÍN HIỆU NỘI BỘ (INTERNAL REGISTERS & SIGNALS)
    // ------------------------------------------------------------------------
    reg [7:0]  enable;                  // Mặt nạ cho phép 8 kênh ngắt (1 = Cho phép)
    reg [7:0]  pending;                 // Cờ chốt lưu vết các sự kiện ngắt đang chờ
    reg [31:0] stamp;                   // Chốt giá trị cycle_count tại chu kỳ irq bật lên 1
    reg        irq_q;                   // Thanh ghi trễ 1 chu kỳ để phát hiện sườn lên của tín hiệu irq

    // ------------------------------------------------------------------------
    // LOGIC TỔNG HỢP ĐƯỜNG NGẮT (INTERRUPT GENERATION LOGIC)
    // ------------------------------------------------------------------------
    // Chỉ các nguồn ngắt có cờ pending VÀ được bật trong enable mới được kích hoạt
    assign ip  = pending & enable;
    
    // Tín hiệu ngắt toàn cục gửi sang CPU: Bật khi có ít nhất 1 nguồn ngắt hợp lệ
    assign irq = |ip;

    // Mặt nạ các bit CPU yêu cầu xóa: Chỉ tích cực khi có lệnh ghi vào A_PEND
    wire [7:0] clr = (bus_we && (bus_addr == A_PEND)) ? bus_wdata[7:0] : 8'd0;

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ (SEQUENTIAL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            enable    <= 8'd0;
            pending   <= 8'd0;
            stamp     <= 32'd0;
            irq_q     <= 1'b0;
            bus_rdata <= 32'd0;
        end else begin
            // 1. Quản lý cờ ngắt pending với cơ chế W1C và ưu tiên sự kiện mới:
            // Xóa bit CPU yêu cầu qua clr, đồng thời tích lũy xung sự kiện mới qua ev.
            // Nếu cùng chu kỳ một bit vừa bị xóa vừa có xung ev mới, ev sẽ thắng.
            pending <= (pending & ~clr) | ev;

            // 2. Cập nhật thanh ghi mặt nạ enable
            if (bus_we && (bus_addr == A_EN)) begin
                enable <= bus_wdata[7:0];
            end

            // 3. Phát hiện sườn lên của irq để chụp mốc chu kỳ stamp
            irq_q <= irq;
            if (irq && !irq_q) begin
                stamp <= cycle_count;
            end

            // 4. Giao diện đọc bus MMIO
            if (bus_re) begin
                case (bus_addr)
                    A_EN: begin
                        bus_rdata <= {24'd0, enable};
                    end
                    A_PEND: begin
                        bus_rdata <= {24'd0, pending};
                    end
                    A_STAMP: begin
                        bus_rdata <= stamp;
                    end
                    default: begin
                        bus_rdata <= 32'd0;
                    end
                endcase
            end
        end
    end

    // Khử cảnh báo linter đối với các bit dữ liệu ghi không dùng
    wire unused_ok = &{1'b0, bus_wdata[31:8]};

endmodule
