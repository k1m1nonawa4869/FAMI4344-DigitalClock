// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     display_ctrl.v — Bộ Điều Khiển Bộ Nhớ Hiển Thị (Display Controller)
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra, Bộ Nhớ Hiển Thị MMIO (Display RAM)
// VAI TRÒ:        Quản Lý Bảng Hiển Thị 8 Ô, Độ Sáng & Giao Tiếp Bus MMIO
// MÔ TẢ:          Module quản lý không gian nhớ hiển thị (Display RAM) 8 ô chữ số:
//                 - Ánh xạ thanh ghi MMIO: DISP0..DISP7 (0x5C .. 0x78), BLINK_MASK (0x7C),
//                   và BRIGHT (0x80).
//                 - Ghép nối trực tiếp với module quét động LED 7 đoạn seg7_scan.
//                 - Hỗ trợ đồng bộ hóa pha nhấp nháy tức thời (Blink restart) khi CPU ghi cấu hình.
//                 - Các chân VGA được tách rời và giữ ở mức an toàn phục vụ tương thích kiến trúc.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Kiến trúc Bộ Nhớ Hiển Thị Ánh Xạ Bộ Nhớ (Memory-Mapped Display RAM):
//    - Display RAM gồm 8 thanh ghi 8-bit tương ứng 8 chữ số LED (DISP0 bên phải nhất đến DISP7 bên trái nhất).
//    - Cấu trúc từng ô hiển thị 8-bit:
//        + Bit [4:0]: Mã ký tự (0 .. 31) đưa vào bảng char_rom để giải mã 7 đoạn.
//        + Bit [6:5]: Dự phòng (không dùng).
//        + Bit [7]  : Bật/tắt dấu chấm thập phân (Decimal Point - DP): 1 = Sáng, 0 = Tắt.
//    - CPU ghi dữ liệu hiển thị thông qua các lệnh `sw` (Store Word) thông thường vào
//      vùng địa chỉ 0x5C + 4*i (với i = 0..7).
//
// 2. Đồng Bộ Hóa Pha Nhấp Nháy Tức Thời (Blink Restart Mechanism):
//    - Khi người dùng ở chế độ Chỉnh giờ (Set Mode), các chữ số đang chỉnh (giờ, phút hoặc giây)
//      được cấu hình nhấp nháy bằng cách bật bit tương ứng trong thanh ghi `A_BLINK` (0x7C).
//    - Khi chuyển vùng chỉnh (ví dụ từ chỉnh giờ sang chỉnh phút), CPU ghi giá trị mới vào `A_BLINK`.
//    - Tín hiệu `blink_restart` kích hoạt ngay trong chu kỳ ghi đó, reset bộ đếm pha nháy về 0 (pha sáng),
//      ngăn chặn hiện tượng chữ số mới chọn bị tắt ngúm trong 250 ms đầu tiên, mang lại phản hồi tức thì.
//
// 3. Khử Rời Rạc & Tối Ưu Hóa Giao Tiếp:
//    - Toàn bộ các thanh ghi cấu hình hiển thị là thanh ghi chỉ-ghi (Write-Only). Mọi thao tác
//      đọc bus MMIO đều trả về 0x00000000 an toàn theo chuẩn bus MMIO của hệ thống.
// ============================================================================

`timescale 1ns/1ps

module display_ctrl #(
    parameter G_SLOT           = 50000,    // Số chu kỳ xung nhịp cho 1 khe chữ số (1 ms ở 50 MHz)
    parameter G_BLANK          = 100,      // Khoảng làm tối chống bóng ma (2 us)
    parameter G_AN_ACTIVE_LOW  = 0,        // 1 nếu cực Anode tích cực mức thấp
    parameter G_SEG_ACTIVE_LOW = 0         // 1 nếu các thanh đoạn Seg tích cực mức thấp
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,        // Xung nhịp hệ thống 50 MHz
    input  wire        rst,        // Reset đồng bộ mức cao (Active-high Reset)
    input  wire        tick_ms,    // Xung nhịp 1 ms từ bộ chia timebase
    
    // Giao diện Bus MMIO
    input  wire [7:0]  bus_addr,   // Địa chỉ byte offset trong không gian ngoại vi
    input  wire [31:0] bus_wdata,  // Dữ liệu ghi từ CPU
    input  wire        bus_we,     // Tín hiệu ghi MMIO (Write Enable)
    input  wire        bus_re,     // Tín hiệu đọc MMIO (Read Enable)
    output wire [31:0] bus_rdata,  // Dữ liệu đọc trả về cho CPU
    
    // Đầu ra kết nối tới LED 7 đoạn
    output wire [7:0]  an,         // 8 chân chọn chữ số (Anode)
    output wire [6:0]  seg,        // 7 chân dữ liệu đoạn (gfedcba)
    output wire        dp,         // Chân dữ liệu dấu chấm thập phân
    
    // Các đường xuất tín hiệu tương thích kiến trúc SoC
    output wire        vga_hs,     // Tín hiệu đồng bộ ngang (giữ 0 an toàn khi bỏ VGA)
    output wire        vga_vs,     // Tín hiệu đồng bộ dọc (giữ 0 an toàn khi bỏ VGA)
    output wire [11:0] vga_rgb     // Tín hiệu màu RGB (giữ 0 an toàn khi bỏ VGA)
);

    // ------------------------------------------------------------------------
    // ĐỊA CHỈ THANH GHI NGOẠI VI (MMIO REGISTER ADDRESS MAP)
    // ------------------------------------------------------------------------
    localparam A_DISP0  = 8'h5C,   // 0x5C: Ô hiển thị DISP0 (bên phải nhất); DISP_i = 0x5C + 4*i
               A_DISP7  = 8'h78,   // 0x78: Ô hiển thị DISP7 (bên trái nhất)
               A_BLINK  = 8'h7C,   // 0x7C: Mặt nạ nhấp nháy 8 chữ số (Blink Mask)
               A_BRIGHT = 8'h80;   // 0x80: Mức độ sáng PWM (0 .. 15)

    // ------------------------------------------------------------------------
    // BỘ NHỚ HIỂN THỊ (DISPLAY REGISTERS)
    // ------------------------------------------------------------------------
    reg [63:0] disp;               // 8 ô x 8 bit = 64 bit Display RAM
    reg [7:0]  blink_mask;         // Mặt nạ nhấp nháy (1 = Nhấp nháy 2 Hz)
    reg [3:0]  bright;             // Độ sáng 16 mức (0 = Tắt .. 15 = Cực đại)

    // Giải mã địa chỉ ghi Display RAM: 0x5C .. 0x78 (mỗi ô cách nhau 4 byte)
    wire       is_disp = (bus_addr >= A_DISP0) && (bus_addr <= A_DISP7);
    wire [7:0] doff    = bus_addr - A_DISP0;      // Độ lệch offset: 0, 4, 8, ..., 28
    wire [2:0] di      = doff[4:2];               // Chỉ số ô hiển thị (0 .. 7)

    // Xung kích hoạt đồng bộ hóa pha nhấp nháy tức thời khi ghi thanh ghi A_BLINK
    wire       blink_restart = bus_we && (bus_addr == A_BLINK);

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ GHI DỮ LIỆU HIỂN THỊ (SEQUENTIAL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            disp       <= {8{8'h1A}};  // Mặc định sau reset: 8 ô đều là ký tự trống (0x1A)
            blink_mask <= 8'd0;        // Tắt toàn bộ chế độ nhấp nháy
            bright     <= 4'd15;       // Độ sáng mặc định mức cực đại (15)
        end else begin
            if (bus_we) begin
                if (is_disp) begin
                    disp[8*di +: 8] <= bus_wdata[7:0]; // Cập nhật ô hiển thị thứ di
                end else if (bus_addr == A_BLINK) begin
                    blink_mask      <= bus_wdata[7:0]; // Cập nhật mặt nạ nhấp nháy
                end else if (bus_addr == A_BRIGHT) begin
                    bright          <= bus_wdata[3:0]; // Cập nhật độ sáng PWM
                end
            end
        end
    end

    // Các thanh ghi hiển thị là chỉ-ghi (Write-Only), thao tác đọc luôn trả về 0
    assign bus_rdata = 32'd0;

    // ------------------------------------------------------------------------
    // KHỐI QUÉT ĐỘNG LED 7 ĐOẠN GHÉP KÊNH (DYNAMIC SCANNER INSTANCE)
    // ------------------------------------------------------------------------
    wire blink_ph;
    seg7_scan #(
        .G_DIGITS(8),
        .G_MUX(1),
        .G_SLOT(G_SLOT),
        .G_BLANK(G_BLANK),
        .G_AN_ACTIVE_LOW(G_AN_ACTIVE_LOW),
        .G_SEG_ACTIVE_LOW(G_SEG_ACTIVE_LOW)
    ) u_scan (
        .clk(clk),
        .rst(rst),
        .tick_ms(tick_ms),
        .disp(disp),
        .blink_mask(blink_mask),
        .blink_restart(blink_restart),
        .bright(bright),
        .an(an),
        .seg(seg),
        .dp(dp),
        .blink_ph(blink_ph)
    );

    // Giao diện hiển thị đồ họa VGA (đọc chung Display RAM và đồng bộ pha nháy)
    vga_digits u_vga (
        .clk(clk),
        .rst(rst),
        .disp(disp),
        .dim(blink_mask & {8{blink_ph}}),
        .hsync(vga_hs),
        .vsync(vga_vs),
        .rgb(vga_rgb)
    );

endmodule
