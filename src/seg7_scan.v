// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     seg7_scan.v — Quét LED 7 Đoạn Ghép Kênh & Chống Bóng Ma
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra, Quét Hiển Thị Ghép Kênh Thời Gian
// VAI TRÒ:        Bộ Quét Động 8 LED 7 Đoạn & Điều Chế Xung PWM (Dynamic Scanner)
// MÔ TẢ:          Module điều khiển quét động 8 chữ số LED 7 đoạn dùng chung đường bus đoạn:
//                 - Quét ghép kênh thời gian (Time-Multiplexed Scanning) tần số 125 Hz.
//                 - Khoảng làm tối (Blanking Interval) 100 chu kỳ (2 us) chống hiện tượng bóng ma (Ghosting).
//                 - Điều chế độ rộng xung (PWM) 16 mức độ sáng (Bright: 0..15).
//                 - Cơ chế nhấp nháy 2 Hz (Blink Mask) chu kỳ 500 ms đồng bộ hóa tức thời.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Quét Ghép Kênh Thời Gian (Time-Division Multiplexed Scanning - TDM):
//    - Để hiển thị độc lập 8 chữ số LED 7 đoạn kèm dấu chấm, nếu nối trực tiếp (Static Drive)
//      sẽ cần: 8 chữ số * 8 chân = 64 chân I/O của chip FPGA (rất lãng phí).
//    - Giải pháp ghép kênh (Dynamic Drive): Cả 8 chữ số dùng chung 8 chân dữ liệu đoạn (seg, dp).
//      Mỗi chữ số được điều khiển cấp nguồn bởi một chân chọn chữ số riêng (anode/an).
//    - Tại mỗi thời điểm, phần cứng chỉ bật anode của đúng 1 chữ số trong 1 khe thời gian
//      (Slot dài G_SLOT = 50.000 chu kỳ clock = 1 ms).
//    - Tần số quét toàn bộ khung hình 8 chữ số:
//          T_frame = 8 * 1 ms = 8 ms  ==>  f_refresh = 1 / 8 ms = 125 Hz.
//    - Do f_refresh = 125 Hz > 50 Hz (ngưỡng lưu ảnh võng mạc - Persistence of Vision - POV),
//      mắt người nhìn thấy cả 8 chữ số sáng đồng thời, liên tục và không hề bị giật/nháy.
//
// 2. Hiện tượng Bóng Ma LED (Ghosting Artifact) và Khoảng Làm Tối (Blanking Interval):
//    - Nguyên nhân: Các transistor đóng cắt anode trên mạch phần cứng có điện dung ký sinh
//      và thời gian tắt trễ (turn-off delay). Khi chuyển từ chữ số (j-1) sang chữ số j,
//      nếu chân dữ liệu đoạn đổi sang hình mới của chữ số j trong khi transistor của chữ số (j-1)
//      chưa kịp ngắt hoàn toàn, một phần ánh sáng của chữ số j sẽ bị rò và hiển thị mờ trên
//      vị trí chữ số (j-1) (gọi là bóng ma - ghosting).
//    - Giải pháp 2 tầng triệt tiêu bóng ma:
//        + Tầng 1 (Khoảng làm tối G_BLANK = 100 chu kỳ = 2 us): Tại đầu mỗi khe thời gian
//          (c < G_BLANK), toàn bộ các chân anode đều bị cưỡng bức tắt.
//        + Tầng 2 (Bảo toàn mẫu hiển thị cũ): Trong suốt khoảng c < G_BLANK, chân đoạn
//          vẫn được giữ nguyên giá trị của chữ số trước đó (`js = j - 1`). Chỉ khi anode cũ
//          đã ngắt hẳn và anode mới bắt đầu kích hoạt (c >= G_BLANK), hình mới mới được nạp.
//
// 3. Điều chế độ rộng xung PWM điều chỉnh độ sáng (Brightness Control):
//    - Mỗi khe thời gian sau khoảng làm tối được chia thành 15 bước:
//          G_STEP = (G_SLOT - G_BLANK) / 15.
//    - Anode chỉ được bật trong khoảng:
//          G_BLANK <= c < G_BLANK + bright * G_STEP.
//    - Bright = 0: LED tắt hoàn toàn; Bright = 15: LED sáng cực đại.
//
// 4. Cơ chế nhấp nháy 2 Hz (Blink Control):
//    - Bộ đếm bcnt đếm 500 ms (0 .. 499). Pha "tắt" rơi vào nửa sau (250 .. 499 ms).
//    - Các chữ số được đánh dấu trong `blink_mask` sẽ tắt anode trong pha tắt.
//    - Tín hiệu `blink_restart` kích hoạt khi CPU ghi lại `blink_mask`, reset ngay `bcnt = 0`
//      để chữ số bắt đầu ở pha "sáng" tức thì, tránh cảm giác trễ thị giác khi người dùng bấm phím.
// ============================================================================

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module seg7_scan #(
    parameter G_DIGITS         = 8,        // Số chữ số LED 7 đoạn (mặc định = 8)
    parameter G_MUX            = 1,        // Chế độ ghép kênh thời gian (Bắt buộc = 1)
    parameter G_SLOT           = 50000,    // Độ dài 1 khe thời gian: 50.000 chu kỳ clock = 1 ms ở 50 MHz
    parameter G_BLANK          = 100,      // Khoảng làm tối chống bóng ma: 100 chu kỳ = 2 us
    parameter G_AN_ACTIVE_LOW  = 0,        // 1 nếu cực Anode tích cực mức thấp
    parameter G_SEG_ACTIVE_LOW = 0         // 1 nếu các thanh đoạn Seg tích cực mức thấp
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire                    clk,            // Xung nhịp hệ thống 50 MHz
    input  wire                    rst,            // Reset đồng bộ mức cao (Active-high Reset)
    input  wire                    tick_ms,        // Xung nhịp 1 ms từ bộ chia timebase
    
    // Giao diện bộ nhớ hiển thị
    input  wire [8*G_DIGITS-1:0]   disp,           // Mảng dữ liệu 8 ô hiển thị: [4:0] mã ký tự, [7] dấu chấm dp
    input  wire [G_DIGITS-1:0]     blink_mask,     // Mặt nạ cho phép nhấp nháy từng chữ số
    input  wire                    blink_restart,  // Xung đồng bộ pha nhấp nháy khi CPU ghi thanh ghi BLINK
    input  wire [3:0]              bright,         // Mức độ sáng PWM (0 .. 15)
    
    // Các chân kết nối vật lý tới phần cứng LED 7 đoạn
    output wire [G_DIGITS-1:0]     an,             // Chân chọn chữ số (Anode Enable)
    output wire [6:0]              seg,            // Chân dữ liệu 7 đoạn: gfedcba
    output wire                    dp,             // Chân dữ liệu dấu chấm thập phân
    output wire                    blink_ph        // Pha nhấp nháy hiện tại (1 = pha tắt, 0 = pha sáng)
);

`ifndef SYNTHESIS
    initial if (G_MUX != 1) $display("ERROR seg7_scan: Chi ho tro che do quet ghep kenh G_MUX = 1");
`endif

    // ------------------------------------------------------------------------
    // CÁC HẰNG SỐ VÀ ĐỘ RỘNG BIT CỦA BỘ ĐẾM (LOCAL PARAMETERS)
    // ------------------------------------------------------------------------
    localparam G_STEP = (G_SLOT - G_BLANK) / 15;     // Số chu kỳ clock tương ứng mỗi bước tăng độ sáng
    localparam CW     = $clog2(G_SLOT);              // Độ rộng bit của bộ đếm vị trí chu kỳ c trong khe
    localparam JW     = (G_DIGITS > 1) ? $clog2(G_DIGITS) : 1; // Độ rộng bit của chỉ số chữ số j (0..7)

    // ------------------------------------------------------------------------
    // THANH GHI NỘI BỘ (INTERNAL REGISTERS)
    // ------------------------------------------------------------------------
    reg [CW-1:0] c;       // Bộ đếm chu kỳ clock trong khe hiện tại (0 .. G_SLOT - 1)
    reg [JW-1:0] j;       // Chỉ số chữ số đang được quét (0 .. G_DIGITS - 1)
    reg [8:0]    bcnt;    // Bộ đếm mili-giây cho chu kỳ nhấp nháy 500 ms (0 .. 499)

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ QUẢN LÝ KHE THỜI GIAN & PHA NHẤP NHÁY
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            c    <= {CW{1'b0}};
            j    <= {JW{1'b0}};
            bcnt <= 9'd0;
        end else begin
            // Tiến trình đếm khe thời gian và luân phiên chữ số
            if (c == G_SLOT - 1) begin
                c <= {CW{1'b0}};
                j <= (j == G_DIGITS - 1) ? {JW{1'b0}} : j + 1'b1;
            end else begin
                c <= c + 1'b1;
            end

            // Tiến trình đếm pha nhấp nháy (chu kỳ 500 ms = 2 Hz)
            if (blink_restart) begin
                bcnt <= 9'd0;      // Bắt đầu lại ngay từ pha sáng khi có lệnh cấu hình mới
            end else if (tick_ms) begin
                bcnt <= (bcnt == 9'd499) ? 9'd0 : bcnt + 9'd1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // MẠCH CHỐNG BÓNG MA (ANTI-GHOSTING LOGIC)
    // ------------------------------------------------------------------------
    // Trong khoảng c < G_BLANK: Giữ nguyên hình của chữ số trước đó (j - 1) để tránh
    // rò rỉ ánh sáng khi transistor cũ chưa kịp ngắt hoàn toàn.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [JW-1:0] js  = (c < G_BLANK) ? ((j == 0) ? G_DIGITS - 1 : j - 1'b1) : j;
    wire [7:0]    cur = disp[8*js +: 8];
    /* verilator lint_on UNUSEDSIGNAL */

    // Tra cứu giải mã 7 đoạn từ mã ký tự 5-bit
    wire [6:0] rom_seg;
    char_rom u_rom (
        .code(cur[4:0]),
        .seg(rom_seg)
    );

    // ------------------------------------------------------------------------
    // LOGIC ĐIỀU CHẾ ĐỘ SÁNG PWM & ĐIỀU KHIỂN ANODE
    // ------------------------------------------------------------------------
    // Pha nháy: Nửa sau (250 .. 499 ms) là pha "tắt"
    assign blink_ph = (bcnt >= 9'd250);
    
    // Chữ số j bị tắt nếu được đánh dấu trong blink_mask và đang trong pha tắt
    wire blink_off  = blink_mask[j] && blink_ph;
    
    // Điều kiện bật sáng chữ số j: Đã qua khoảng blanking, nằm trong vùng độ sáng PWM và không bị tắt nháy
    wire lit        = (c >= G_BLANK) && (c < G_BLANK + bright * G_STEP) && !blink_off;

    // Mã hóa One-hot cho Anode: Chỉ bật đúng bit j khi lit = 1
    wire [G_DIGITS-1:0] an_hi = lit ? ({{(G_DIGITS-1){1'b0}}, 1'b1} << j) : {G_DIGITS{1'b0}};

    // Chuyển đổi mức logic theo cấu hình cực tính phần cứng
    assign an  = (G_AN_ACTIVE_LOW  != 0) ? ~an_hi   : an_hi;
    assign seg = (G_SEG_ACTIVE_LOW != 0) ? ~rom_seg : rom_seg;
    assign dp  = (G_SEG_ACTIVE_LOW != 0) ? ~cur[7]  : cur[7];

endmodule
