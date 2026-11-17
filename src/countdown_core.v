// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     countdown_core.v — Khối Đếm Lùi & Đếm Quá Giờ Bù Âm (Countdown Core)
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra, Bộ Định Thời (Timers & Down-Counters)
// VAI TRÒ:        Bộ Định Thời Đếm Ngược & Báo Tràn Âm (Programmable Down-Counter)
// MÔ TẢ:          Module đếm ngược thời gian (mili-giây) từ giá trị cài đặt về 0.
//                 Khi chạm 0: Kích hoạt sự kiện ngắt TMR_ZERO và tùy chọn phát còi BEEP.
//                 Đặc biệt: Tiếp tục đếm lùi sang miền số âm bù 2 (-1, -2, ...) để đo
//                 chính xác khoảng thời gian đã quá giờ (Overtime) cho đến khi bão hòa.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Nguyên lý Đếm Lùi Bù Âm (Signed Two's Complement Overtime Counting):
//    - Các bộ đếm ngược vi điều khiển thông thường sẽ tự dừng lại hoặc nạp lại (auto-reload)
//      khi chạm mốc 0.
//    - Tuy nhiên trong ứng dụng thực tế (bấm giờ thi đấu, hẹn giờ bếp, báo thức), người dùng
//      cần biết sự kiện đã quá hạn bao nhiêu giây/phút mà không phải reset lại đồng hồ.
//    - Khối sử dụng thanh ghi 32-bit biểu diễn số nguyên có dấu bù 2 (Signed Two's Complement):
//        + Khi val > 0: Đang trong khoảng thời gian đếm lùi còn lại.
//        + Tại thời điểm val = 1 chuyển sang 0: Sinh xung sự kiện `zero_ev` đúng 1 chu kỳ clock.
//        + Khi val <= 0: Bộ đếm không dừng mà tiếp tục trừ 1 mỗi ms: 0 -> -1 -> -2 ...
//        + Firmware khi đọc giá trị âm sẽ lấy giá trị tuyệt đối |val| và hiển thị dấu "-"
//          nhấp nháy trên LED 7 đoạn để báo cho người dùng biết thời gian quá hạn.
//
// 2. Cơ chế Bão hòa Cận Dưới Âm Cực Đại (Negative Saturation):
//    - Giá trị cận dưới âm cực đại của số bù 2 32-bit: MIN = 32'h8000_0000 (-2^31).
//    - Khi val chạm ngưỡng MIN, bộ đếm dừng lại (không giảm tiếp) và kích hoạt cờ `sat = 1`,
//      ngăn chặn hiện tượng tràn số học (underflow) nhảy vọt sang số dương (+2^31 - 1).
//
// 3. Bộ chia phân số độc lập & Quản lý pha:
//    - Khối tích hợp một bộ chia `timebase` độc lập (`u_div`):
//        + Pha bộ chia được reset về 0 ngay khi CPU ghi giá trị mới vào thanh ghi A_VAL (`clr = w_val`).
//        + Bộ chia chỉ chạy khi cờ `run = 1`.
//      Nhờ đó mili-giây đầu tiên đếm lùi luôn đạt độ dài chuẩn xác 1 ms.
//
// 4. Ưu tiên xử lý xung đột Bus (Hazard & Priority Resolution):
//    - Lệnh ghi dữ liệu mới từ CPU (`w_val`) luôn chiếm ưu tiên cao nhất, thắng xung đếm `tick`
//      nếu xảy ra trong cùng chu kỳ clock.
//    - Khi có sự kiện chạm mốc 0 (`zero_ev`), cờ `zero` được ưu tiên bật lên 1, thắng lệnh xóa
//      của CPU nếu xảy ra đồng thời.
// ============================================================================

`timescale 1ns/1ps

module cdtimer #(
    parameter G_N = 50000              // Số chu kỳ clock / 1 ms (trên FPGA = 50.000; mô phỏng = 50)
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire               clk,      // Xung nhịp hệ thống 50 MHz
    input  wire               rst,      // Reset đồng bộ mức cao (Active-high Reset)
    input  wire signed [31:0] cal,      // Giá trị hiệu chỉnh tần số ppm cho bộ chia riêng
    
    // Giao diện Bus MMIO
    input  wire [7:0]         bus_addr, // Địa chỉ thanh ghi ngoại vi
    input  wire [31:0]        bus_wdata,// Dữ liệu ghi từ CPU
    input  wire               bus_we,   // Tín hiệu ghi MMIO (Write Enable)
    input  wire               bus_re,   // Tín hiệu đọc MMIO (Read Enable)
    output reg  [31:0]        bus_rdata,// Dữ liệu đọc trả về cho CPU
    
    // Tín hiệu ngắt và điều khiển ngoại vi trực tiếp
    output wire               zero_ev,  // Xung sự kiện TMR_ZERO (kết nối tới IRQ Controller bit 2)
    output wire               beep      // Xung kích hoạt còi Beeper trực tiếp khi chạm 0
);

    // ------------------------------------------------------------------------
    // ĐỊA CHỈ THANH GHI NGOẠI VI (MMIO REGISTER ADDRESS MAP)
    // ------------------------------------------------------------------------
    localparam A_VAL = 8'h28,           // 0x28: Thanh ghi giá trị thời gian đếm lùi (32-bit có dấu, R/W)
               A_CTL = 8'h2C;           // 0x2C: Thanh ghi điều khiển & trạng thái (R/W)
    
    // Giá trị âm nhỏ nhất trong hệ bù 2 32-bit: -2.147.483.648
    localparam [31:0] MIN = 32'h8000_0000;

    // ------------------------------------------------------------------------
    // THANH GHI VÀ TÍN HIỆU NỘI BỘ (INTERNAL REGISTERS & SIGNALS)
    // ------------------------------------------------------------------------
    reg [31:0] val;                     // Giá trị thời gian hiện tại (đơn vị: ms, biểu diễn số bù 2 có dấu)
    reg        run;                     // Trạng thái đếm: 1 = Running, 0 = Paused
    reg        zero;                    // Cờ chốt trạng thái đã chạm 0 (Sticky flag, giữ 1 tới khi CPU ghi xóa)
    reg        beep_en;                 // Cho phép tự động kích còi khi chạm 0
    reg        sat;                     // Cờ bão hòa cực âm (đạt ngưỡng MIN)

    // Tín hiệu giải mã ghi thanh ghi từ CPU
    wire w_val = bus_we && (bus_addr == A_VAL);
    wire w_ctl = bus_we && (bus_addr == A_CTL);
    wire tick;                          // Xung nhịp 1 ms sinh từ bộ chia độc lập

    // ------------------------------------------------------------------------
    // BỘ CHIA PHÂN SỐ ĐỘC LẬP (DEDICATED PRESCALER)
    // ------------------------------------------------------------------------
    timebase #(.G_N(G_N)) u_div (
        .clk(clk),
        .rst(rst),
        .clr(w_val),                    // Xóa sạch pha khi nạp giá trị thời gian mới
        .en(run),                       // Chỉ đếm khi cờ run bật
        .cal(cal),
        .tick(tick)
    );

    // ------------------------------------------------------------------------
    // LOGIC PHÁT HIỆN CHẠM 0 & PHÁT CÒI (ZERO DETECTION & BEEP TRIGGER)
    // ------------------------------------------------------------------------
    // Phát hiện đúng thời khắc giá trị chuyển từ 1 xuống 0 tại sườn tick_ms;
    // Bỏ qua nếu trong cùng chu kỳ CPU ghi nạp giá trị mới vào A_VAL
    assign zero_ev = tick && !w_val && (val == 32'd1);
    
    // Xung kích còi chỉ bật khi có sự kiện zero_ev VÀ bit cho phép beep_en đang bật
    assign beep    = zero_ev && beep_en;

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ (SEQUENTIAL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            val       <= 32'd0;
            run       <= 1'b0;
            zero      <= 1'b0;
            beep_en   <= 1'b0;
            sat       <= 1'b0;
            bus_rdata <= 32'd0;
        end else begin
            // ----------------------------------------------------------------
            // 1. TIẾN TRÌNH ĐẾM LÙI THỜI GIAN
            // ----------------------------------------------------------------
            if (w_val) begin
                // Lệnh ghi nạp thời gian từ CPU có độ ưu tiên cao nhất
                val <= bus_wdata;
                sat <= 1'b0;
            end else if (tick) begin
                if (val == MIN) begin
                    sat <= 1'b1;        // Đạt cực âm bão hòa, giữ nguyên giá trị
                end else begin
                    val <= val - 32'd1; // Giảm 1 ms mỗi nhịp tick, tự nhiên vượt qua 0 sang số âm
                end
            end

            // ----------------------------------------------------------------
            // 2. ĐIỀU KHIỂN TRẠNG THÁI (CONTROL REGISTER BITS)
            // ----------------------------------------------------------------
            if (w_ctl) begin
                run     <= bus_wdata[0]; // Bit [0]: RUN
                beep_en <= bus_wdata[2]; // Bit [2]: BEEP_EN
            end

            // Quản lý cờ chốt zero (Sticky zero flag):
            // Sự kiện zero_ev tự động set cờ lên 1 (chiếm ưu tiên nếu CPU đồng thời ghi xóa)
            if (zero_ev) begin
                zero <= 1'b1;
            end else if (w_ctl && bus_wdata[1]) begin
                zero <= 1'b0;            // Ghi bit [1] = 1 để xóa cờ zero
            end

            // ----------------------------------------------------------------
            // 3. GIAO DIỆN ĐỌC BUS MMIO (BUS READ LOGIC)
            // ----------------------------------------------------------------
            if (bus_re) begin
                case (bus_addr)
                    A_VAL: begin
                        bus_rdata <= val;
                    end
                    A_CTL: begin
                        // Định dạng thanh ghi A_CTL:
                        // [31:4] = 0
                        // [3]    = sat     (cờ bão hòa cực âm)
                        // [2]    = beep_en (cho phép phát còi khi chạm 0)
                        // [1]    = zero    (cờ trạng thái đã chạm 0)
                        // [0]    = run     (trạng thái đang chạy)
                        bus_rdata <= {28'd0, sat, beep_en, zero, run};
                    end
                    default: begin
                        bus_rdata <= 32'd0;
                    end
                endcase
            end
        end
    end

    // Khử cảnh báo linter đối với các bit dữ liệu ghi không dùng
    wire unused_ok = &{1'b0, bus_wdata[31:3]};

endmodule
