// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     soc_regs.v — Thanh Ghi Hệ Thống & Bộ Điều Khiển Nhịp CPU
// VAI TRÒ:        Quản lý các thanh ghi điều khiển cấp hệ thống (CYCLE_COUNT,
//                 CAL, CPU_CLK_DIV, DIV_FLAGS) và sinh tín hiệu xung nhịp
//                 cho phép bước CPU (cpu_ce - Clock Enable)
// ============================================================================
// 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
//    - Phương trình hiệu năng máy tính (Patterson & Hennessy §1.6):
//        t_CPU = (IC × CPI) / f_0 = CYCLE_COUNT × T_clk
//      Thanh ghi CYCLE_COUNT 32-bit đếm liên tục mỗi chu kỳ xung nhịp hệ thống
//      (50 MHz -> T_clk = 20 ns), cung cấp tem thời gian phần cứng chuẩn xác
//      để đo lường số chu kỳ CPU, độ trễ xử lý ngắt và hiệu năng tập lệnh.
//    - Kỹ thuật điều khiển nhịp đồng bộ qua Clock Enable (Clock Gating/CE):
//      Thay vì phân rã thành nhiều mạng phân phối xung nhịp vật lý (Clock Trees)
//      gây độ lệch pha (Clock Skew) nguy hiểm giữa các flip-flop, chuẩn công
//      nghiệp SoC sử dụng một xung nhịp duy nhất (50 MHz) và điều chế tốc độ
//      thực thi của CPU bằng tín hiệu cho phép nhịp tuần tự (cpu_ce).
//    - Bù trôi tần số thạch anh (Crystal Drift Calibration):
//      Thanh ghi CAL 32-bit có dấu lưu hệ số hiệu chuẩn theo đơn vị phần triệu
//      (ppm), chuyển tiếp trực tiếp sang khối timebase.v để hiệu chỉnh nhịp 1 ms.
//
// 2. NGUYÊN LÝ HOẠT ĐỘNG & BỘ GIẢI MÃ BUS (ARCHITECTURE & BUS LOGIC):
//    - Ánh xạ thanh ghi qua Bus MMIO 8-bit (Base 0xFFFF0000):
//        + 0x00: CYCLE_COUNT (32-bit, Read-Only) - Đếm chu kỳ hệ thống từ lúc reset.
//        + 0x18: CAL         (32-bit signed, R/W) - Hệ số bù trôi thạch anh.
//        + 0x8C: CPU_CLK_DIV (16-bit D, R/W) - Tỷ số chia xung nhịp cho CPU.
//        + 0x90: DIV_FLAGS   (32-bit, Read-Only, bit 0: div_dz) - Cờ chia cho 0.
//    - Quy tắc chuẩn hóa hệ số chia D (Normalization Rule):
//        + CPU G1 (Single-Cycle 2-Phase): Mỗi chu kỳ lệnh cần 2 xung cpu_ce (Pha B
//          giải mã/tính toán, Pha A ghi/chốt). Do đó D phải >= 2 và là số chẵn.
//          Khoảng cách giữa 2 xung cpu_ce là period = D / 2.
//        + CPU G2 (5-Stage Pipeline): D >= 1. Mỗi chu kỳ bước 1 tầng pipeline.
//          Khoảng cách xung cpu_ce là period = D chu kỳ hệ thống.
//    - Cơ chế cập nhật D an toàn (Glitch-Free Divisor Update):
//      Khi CPU ghi giá trị D mới qua lệnh sw, giá trị mới chỉ được nạp vào
//      bộ đếm chu kỳ p tại sườn cpu_ce kế tiếp. Nửa sau của lệnh ghi vẫn duy
//      trì theo D cũ, đảm bảo không làm co ngắn chu kỳ xung nhịp CPU hiện tại.
//
// 3. CHI TIẾT CỔNG GIAO TIẾP VÀ THAM SỐ (INTERFACE & PARAMETERS):
//    - G_CORE: 1 = Lõi đơn chu kỳ G1 (mặc định D = 2); 2 = Lõi đường ống G2 (D = 1).
//    - bus_addr[7:0], bus_wdata[31:0], bus_we, bus_re: Giao diện bus MMIO đồng bộ.
//    - div_dz: Tín hiệu cờ chia 0 nhận từ khối muldiv.v.
//    - cpu_ce: Tín hiệu tích cực cao trong 1 chu kỳ hệ thống cho phép CPU hoạt động.
// ============================================================================

`timescale 1ns/1ps

module soc_regs #(
    parameter G_CORE = 1                 // 1 = G1 (D >= 2, chẵn; reset 2), 2 = G2 (D >= 1; reset 1)
) (
    input  wire        clk,              // Xung nhịp hệ thống 50 MHz
    input  wire        rst,              // Tín hiệu reset đồng bộ tích cực cao
    input  wire [7:0]  bus_addr,         // Địa chỉ thanh ghi MMIO 8-bit
    input  wire [31:0] bus_wdata,        // Dữ liệu ghi từ CPU
    input  wire        bus_we,           // Tín hiệu ghi thanh ghi MMIO
    input  wire        bus_re,           // Tín hiệu đọc thanh ghi MMIO
    output reg  [31:0] bus_rdata,        // Dữ liệu đọc trả về bus CPU (tự về 0 khi không trúng địa chỉ)
    input  wire        div_dz,           // Cờ báo lệnh chia gần nhất bị chia cho 0 (từ muldiv)
    output reg  [31:0] cycle_count,      // Bộ đếm chu kỳ hệ thống (cho IRQ_STAMP và đo đạc)
    output reg  signed [31:0] cal,       // Giá trị hiệu chỉnh ppm gửi sang timebase
    output wire        cpu_ce            // Xung cho phép CPU bước (Clock Enable)
);

    // ------------------------------------------------------------------------
    // ĐỊA CHỈ THANH GHI NỘI BỘ (INTERNAL REGISTER OFFSETS)
    // ------------------------------------------------------------------------
    localparam A_CYCLE = 8'h00,          // Offset 0x00: CYCLE_COUNT (Read-Only)
               A_CAL   = 8'h18,          // Offset 0x18: CAL (Read/Write)
               A_DIV   = 8'h8C,          // Offset 0x8C: CPU_CLK_DIV (Read/Write)
               A_FLAGS = 8'h90;          // Offset 0x90: DIV_FLAGS (Read-Only)

    // ------------------------------------------------------------------------
    // CÁC THANH GHI NỘI BỘ & BỘ ĐẾM CHIA TẦN (REGISTERS & DIVIDER COUNTERS)
    // ------------------------------------------------------------------------
    reg  [15:0] d;                       // Hệ số chia D đã chuẩn hóa
    reg  [15:0] c;                       // Bộ đếm chu kỳ tới xung cpu_ce tiếp theo
    reg  [15:0] p;                       // Khoảng chu kỳ thực tế đang áp dụng giữa 2 xung cpu_ce
    wire [15:0] period = (G_CORE == 1) ? {1'b0, d[15:1]} : d;    // G1: D/2 (D chẵn), G2: D

    // ------------------------------------------------------------------------
    // HÀM CHUẨN HÓA GIÁ TRỊ D (NORMALIZATION FUNCTION)
    // ------------------------------------------------------------------------
    function [15:0] norm(input [15:0] v);
        begin
            if (G_CORE == 1)
                norm = (v < 16'd2) ? 16'd2 : {v[15:1], 1'b0};   // G1: D >= 2, xóa bit 0 để luôn chẵn
            else
                norm = (v == 16'd0) ? 16'd1 : v;                 // G2: D >= 1
        end
    endfunction

    // ------------------------------------------------------------------------
    // TẠO XUNG CHO PHÉP CPU (CPU CLOCK ENABLE GENERATION)
    // ------------------------------------------------------------------------
    // cpu_ce tích cực cao trong đúng 1 chu kỳ clk khi bộ đếm c đạt p - 1
    assign cpu_ce = !rst && (c >= p - 16'd1);

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ: ĐẾM CHU KỲ, CẬP NHẬT D & GIAO DIỆN BUS MMIO
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 32'd0;
            cal         <= 32'sd0;
            d           <= (G_CORE == 1) ? 16'd2 : 16'd1;
            c           <= 16'd0;
            p           <= 16'd1;        // G1 D=2 -> p=1; G2 D=1 -> p=1
            bus_rdata   <= 32'd0;
        end else begin
            // 1. Tăng bộ đếm chu kỳ hệ thống liên tục
            cycle_count <= cycle_count + 32'd1;

            // 2. Bộ đếm chu kỳ phát xung cpu_ce
            c <= cpu_ce ? 16'd0 : c + 16'd1;

            // 3. Cập nhật chu kỳ mới an toàn: Chỉ chốt p tại thời điểm phát cpu_ce
            if (cpu_ce)
                p <= period;

            // 4. Ghi bus MMIO (Bus Write)
            if (bus_we) begin
                case (bus_addr)
                    A_CAL: cal <= bus_wdata;
                    A_DIV: d   <= norm(bus_wdata[15:0]);
                    default: ;           // CYCLE_COUNT, DIV_FLAGS là thanh ghi chỉ đọc (Read-Only)
                endcase
            end

            // 5. Đọc bus MMIO (Bus Read)
            if (bus_re) begin
                case (bus_addr)
                    A_CYCLE: bus_rdata <= cycle_count;
                    A_CAL:   bus_rdata <= cal;
                    A_DIV:   bus_rdata <= {16'd0, d};
                    A_FLAGS: bus_rdata <= {31'd0, div_dz};
                    default: bus_rdata <= 32'd0;    // Không trúng địa chỉ: trả về 0 để phục vụ phép OR Bus
                endcase
            end
        end
    end

    // Xử lý cảnh báo linter về các bit cao chưa dùng của bus_wdata
    wire unused_ok = &{1'b0, bus_wdata[31:16]};

endmodule
