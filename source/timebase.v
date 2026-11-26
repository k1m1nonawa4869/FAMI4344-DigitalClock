// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     timebase.v — Bộ Chia Phân Số & Hiệu Chỉnh Tần Số (Fractional Timebase)
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra, Bộ Định Thời (Timers & Clock Generators)
// VAI TRÒ:        Bộ Tích Lũy Pha & Tạo Xung Cơ Sở Hệ Thống (Phase Accumulator & Base Tick)
// MÔ TẢ:          Module sinh xung nhịp chuẩn 1 ms (1 kHz) từ nguồn xung thạch anh
//                 hệ thống 50 MHz (mặc định G_N = 50.000 chu kỳ/ms).
//                 Tích hợp giải thuật Tích Lũy Pha Phân Số (Fractional Phase Accumulator)
//                 và thanh ghi hiệu chỉnh CAL 32-bit có dấu bù sai số thạch anh
//                 theo đơn vị phần triệu (Parts-Per-Million - ppm).
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ HOẠT ĐỘNG (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Vấn đề trôi tần số thạch anh (Crystal Frequency Drift):
//    - Các bộ dao động thạch anh thương mại trên FPGA (như Cyclone IV) luôn có
//      sai số chế tạo và trôi nhiệt độ trong khoảng ±20 ppm đến ±100 ppm.
//    - Nếu chỉ dùng bộ đếm số nguyên đơn thuần chia cố định cho 50.000:
//      Độ lệch 50 ppm sẽ làm đồng hồ chạy sai:
//      50 ppm = 50 * 10^-6 * 86.400 giây/ngày ≈ 4,32 giây/ngày.
//
// 2. Nguyên lý Tích Lũy Pha Phân Số (Fractional Phase Accumulator):
//    - Để bù lại độ lệch này với độ chính xác cao mà không cần thay đổi phần cứng
//      dao động analog bên ngoài, ta dùng kỹ thuật tích lũy sai số phân số:
//    - Thanh ghi `frac` (16-bit) lưu trữ phần lẻ tích lũy (đơn vị 1 / 65536 chu kỳ clock).
//    - Tại mỗi mili-giây thứ k, thanh ghi hiệu chỉnh CAL (32-bit có dấu) được cộng vào `frac`:
//        s_k      = frac_k + CAL
//        len_k    = G_N + (s_k >>> 16)      (dịch số học sang phải 16 bit lấy phần nguyên làm tròn dưới - floor)
//        frac_k+1 = s_k[15:0]               (giữ lại 16 bit phần lẻ cho mili-giây kế tiếp)
//
// 3. Quy ước dấu và chuyển đổi đơn vị ppm:
//    - CAL > 0: mili-giây dài thêm các chu kỳ xung nhịp -> đồng hồ chạy chậm lại.
//    - CAL < 0: mili-giây ngắn bớt các chu kỳ xung nhịp -> đồng hồ chạy nhanh lên.
//    - Tính toán giá trị thanh ghi CAL tương ứng với độ lệch 1 ppm:
//      Ở tần số f = 50 MHz (G_N = 50.000 chu kỳ/ms, độ phân giải 2^16 = 65.536):
//      1 ppm tương ứng với:
//        CAL_1ppm = (50.000 * 65.536) / 10^6 = 3.276,8 đơn vị CAL.
//      Ví dụ: Bù trôi +50 ppm -> nạp CAL = 50 * 3.276,8 = 163.840 (0x00028000).
//      Khi đó s_k >>> 16 sẽ luân phiên tạo ra các mili-giây có độ dài 50.002 và 50.003 chu kỳ,
//      đạt độ chính xác trung bình dài hạn hoàn hảo.
//
// 4. Cơ chế chốt an toàn chống chạy sai nhịp (Glitch-Free Latching):
//    - Để tránh việc CPU thay đổi giá trị thanh ghi CAL ngay giữa một mili-giây
//      làm thay đổi đột ngột điều kiện kết thúc `len_k` gây treo bộ đếm, giá trị s_k
//      được chốt vào `s_q` ngay ở đầu mỗi ms (cnt == 0). Bất kỳ thay đổi CAL nào
//      từ phần mềm chỉ có hiệu lực từ mili-giây tiếp theo.
// ============================================================================

`timescale 1ns/1ps

module timebase #(
    parameter G_N = 50000              // Số chu kỳ xung nhịp trên 1 ms (trên FPGA = 50.000; mô phỏng = 50)
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire               clk,     // Xung nhịp hệ thống 50 MHz
    input  wire               rst,     // Reset đồng bộ mức cao (Active-high Reset)
    input  wire               clr,     // Xóa pha đồng bộ: cnt <= 0, frac <= 0
    input  wire               en,      // Tín hiệu cho phép đếm (Clock Enable): 0 = tạm dừng đếm
    input  wire signed [31:0] cal,     // Giá trị hiệu chỉnh độ lệch ppm (32-bit có dấu bù 2)
    output wire               tick     // Xung nhịp 1 chu kỳ tích cực mức cao ở cuối mỗi 1 ms
);

    // ------------------------------------------------------------------------
    // THANH GHI VÀ TÍN HIỆU NỘI BỘ (INTERNAL REGISTERS & SIGNALS)
    // ------------------------------------------------------------------------
    reg        [31:0] cnt;             // Bộ đếm chu kỳ clock trong phạm vi ms hiện tại (0 .. len_k - 1)
    reg        [15:0] frac;            // Thanh ghi tích lũy phần lẻ pha phân số (đơn vị 1/65536 chu kỳ)
    reg signed [33:0] s_q;             // Giá trị tổng pha tích lũy s_k được chốt cho ms đang thực thi

    // ------------------------------------------------------------------------
    // TÍNH TOÁN PHA VÀ ĐỘ DÀI CHU KỲ (PHASE COMPUTATION & ARITHMETIC)
    // ------------------------------------------------------------------------
    // Tại chu kỳ đầu tiên của ms (cnt == 0), tính toán tổng s_now = frac + CAL
    // Ép kiểu signed và mở rộng bit có dấu chính xác lên 34 bit để tránh tràn số học
    wire signed [33:0] s_now = $signed({18'd0, frac}) + $signed({{2{cal[31]}}, cal});

    // Nếu đang ở chu kỳ đầu (cnt == 0), lấy s_now; các chu kỳ sau của ms dùng bản s_q đã chốt
    wire signed [33:0] s_cur = (cnt == 32'd0) ? s_now : s_q;

    // Phép dịch phải số học (>>> 16): Bảo toàn dấu của CAL âm để rút ngắn độ dài ms
    wire signed [33:0] len   = G_N + (s_cur >>> 16);

    // Tín hiệu tick bật đúng 1 chu kỳ tại nhịp cuối cùng của mili-giây (cnt == len - 1)
    assign tick = en && ($signed({2'b00, cnt}) == len - 1);

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ ĐIỀU KHIỂN BỘ ĐẾM (SEQUENTIAL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst || clr) begin
            cnt  <= 32'd0;
            frac <= 16'd0;
            s_q  <= 34'sd0;
        end else if (en) begin
            if (cnt == 32'd0)
                s_q <= s_now;          // Chốt s_k tại đầu ms chống race-condition khi phần mềm ghi CAL
            
            if (tick) begin
                cnt  <= 32'd0;         // Hoàn tất 1 ms: Reset bộ đếm về 0 bắt đầu ms mới
                frac <= s_cur[15:0];   // Chuyển 16-bit phần dư tích lũy sang ms kế tiếp
            end else begin
                cnt  <= cnt + 32'd1;   // Tăng bộ đếm chu kỳ clock
            end
        end
    end

endmodule
