// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     bcd_unit.v — Đơn vị Chuyển Đổi Nhị Phân Sang BCD (Binary to BCD)
// CHUYÊN ĐỀ KTMT: Chương 02: Hệ đếm & Logic số / Chương 03: Số học máy tính
// VAI TRÒ:        Khối Chuyển Đổi Cơ Số Phần Cứng (Hardware Base Conversion Unit)
// MÔ TẢ:          Hiện thực giải thuật Double-Dabble (Shift-and-Add-3) chuyển đổi
//                 số nhị phân (0 .. 99.999.999) thành 8 chữ số BCD (mỗi chữ số 4-bit)
//                 phục vụ giải mã hiển thị trên LED 7 đoạn.
//                 Hỗ trợ 2 chế độ kiến trúc (Design Space Exploration - DSE):
//                 - G_COMB = 0: Kiến trúc tuần tự (Sequential) 27 bước (tiết kiệm diện tích).
//                 - G_COMB = 1: Kiến trúc tổ hợp (Combinational) 27 tầng (tốc độ cao).
// ============================================================================

`timescale 1ns/1ps

module bcd_unit #(
    parameter G_COMB = 0       // Tham số DSE: 0 = Tuần tự (tiết kiệm LUTs), 1 = Tổ hợp (nhanh, tốn LUTs)
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,    // Xung nhịp hệ thống (System Clock)
    input  wire        rst,    // Reset đồng bộ mức cao (Active-high Reset)
    input  wire        ce,     // Clock Enable (chu kỳ CPU)
    input  wire        start,  // Xung khởi động phép chuyển đổi BCD
    input  wire [31:0] x,      // Giá trị số nhị phân 32-bit cần chuyển đổi
    output wire        busy,   // Báo trạng thái bộ chuyển đổi đang bận (CPU chèn Stall)
    output wire        done,   // Báo kết quả BCD đã sẵn sàng ghi vào thanh ghi rd
    output wire [31:0] y       // 8 chữ số BCD kết quả (mỗi chữ số 4-bit, hàng đơn vị tại [3:0])
);

    // ------------------------------------------------------------------------
    // GIỚI HẠN HIỂN THỊ CỦA 8 LED 7 THANH (MAX VALUE = 99,999,999)
    // ------------------------------------------------------------------------
    // Số lớn nhất hiển thị được trên 8 chữ số thập phân là 99.999.999.
    // Vì 99.999.999 < 2^27 = 134.217.728, ta chỉ cần chuyển đổi đúng 27 bit nhị phân (x[26:0]).
    // Nếu giá trị đầu vào vượt quá 99.999.999, phần cứng báo lỗi tràn bằng giá trị 0xFFFFFFFF.
    localparam [31:0] MAXV = 32'd99999999;

    // ------------------------------------------------------------------------
    // NGUYÊN LÝ THUẬT TOÁN DOUBLE-DABBLE (SHIFT-AND-ADD-3 ALGORITHM)
    // ------------------------------------------------------------------------
    // 1. Bản chất: Chuyển đổi từ cơ số 2 sang cơ số 10 bằng cách dịch bit nhị phân
    //    lần lượt từ MSB xuống LSB vào thanh ghi tích lũy BCD.
    //
    // 2. Phép dịch trái (Shift Left) tương đương với phép nhân 2:
    //    Trong hệ thập phân (cơ số 10), khi nhân đôi một chữ số d:
    //    - Nếu d < 5: 2 * d < 10 (chưa tràn hàng chục, ví dụ: 4 * 2 = 8).
    //    - Nếu d >= 5: 2 * d >= 10 (sinh số nhớ 1 sang hàng chục và giữ lại 2*d - 10 ở hàng đơn vị).
    //
    // 3. Tại sao phải cộng 3 trước khi dịch (Add-3 Before Shift)?
    //    Mỗi chữ số BCD được chứa trong một ô 4-bit (Nibble). Nibble 4-bit tự nhiên đếm theo hệ 16.
    //    - Khi dịch trái 1 bit, nibble nhân 2. Sự chênh lệch giữa hệ 16 và hệ 10 là 6 (16 - 10 = 6).
    //    - Vì sau đó ta nhân 2 (dịch trái), ta phải bù trước: 6 / 2 = 3.
    //    - Khi cộng 3 trước khi dịch: (d + 3) * 2 = 2*d + 6.
    //      * Với d = 5: (5 + 3) * 2 = 16 = 0x10 -> Tự động tràn 1 sang nibble kế tiếp, để lại 0.
    //      * Với d = 9: (9 + 3) * 2 = 24 = 0x18 -> Tự động tràn 1 sang nibble kế tiếp, để lại 8 (9*2=18).
    // ------------------------------------------------------------------------

    // Hàm phụ trợ: Duyệt qua 8 chữ số BCD (mỗi chữ số 4 bit), nếu chữ số >= 5 thì cộng thêm 3
    function [31:0] add3(input [31:0] v);
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                add3[4*k +: 4] = (v[4*k +: 4] >= 4'd5) ? (v[4*k +: 4] + 4'd3) : v[4*k +: 4];
            end
        end
    endfunction

    // ------------------------------------------------------------------------
    // BẢN TỔ HỢP 27 TẦNG (COMBINATIONAL IMPLEMENTATION)
    // ------------------------------------------------------------------------
    // Thực hiện lặp unroll liên tục 27 bước chuyển đổi trong 1 chu kỳ logic tổ hợp
    function [31:0] to_bcd(input [26:0] b_in);
        integer k;
        reg [31:0] d;
        begin
            d = 32'd0;
            for (k = 26; k >= 0; k = k - 1) begin
                d = {add3(d)} << 1 | {31'd0, b_in[k]};
            end
            to_bcd = d;
        end
    endfunction

    // Phát hiện tràn số: nếu x vượt ngưỡng 99.999.999
    wire ovf = (x > MAXV);

    // ------------------------------------------------------------------------
    // CẤU HÌNH KIẾN TRÚC THEO THAM SỐ G_COMB (DESIGN SPACE EXPLORATION)
    // ------------------------------------------------------------------------
    generate 
        if (G_COMB != 0) begin : g_comb
            // Bản tổ hợp (Combinational): Kết quả xuất hiện tức thì trong cùng chu kỳ CPU
            assign busy = 1'b0;                 // Không bao giờ làm treo CPU
            assign done = ce && start;          // Hoàn thành ngay khi nhận xung start
            assign y    = ovf ? 32'hFFFFFFFF : to_bcd(x[26:0]);
            wire unused_ok = &{1'b0, clk, rst}; // Tránh cảnh báo unused wire của linter
        end else begin : g_seq
            // Bản tuần tự (Sequential): Thực hiện 27 nhịp clock, tiết kiệm diện tích mạch (~150 LUTs)
            reg        run;    // FSM trạng thái đang tính toán
            reg [4:0]  cnt;    // Bộ đếm 27 bước (0 đến 26)
            reg [31:0] d;      // Thanh ghi tích lũy các chữ số BCD
            reg [26:0] b;      // Thanh ghi chứa các bit nhị phân còn lại (dịch từ bit 26)

            // Mỗi nhịp: Cộng 3 vào chữ số >= 5, dịch trái 1 bit và kéo bit MSB của b vào
            wire [31:0] d_n  = {add3(d)} << 1 | {31'd0, b[26]};
            // Bước thứ 27 (bước cuối cùng của thuật toán)
            wire        last = run && (cnt == 5'd26);

            assign busy = run;
            // Báo hoàn thành: Bật ngay nếu tràn số ở chu kỳ start, hoặc bật ở chu kỳ thứ 27
            assign done = ce && ((start && !run && ovf) || last);
            assign y    = run ? d_n : 32'hFFFFFFFF;

            always @(posedge clk) begin
                if (rst) begin
                    run <= 1'b0;
                    cnt <= 5'd0;
                    d   <= 32'd0;
                    b   <= 27'd0;
                end else if (ce) begin
                    if (start && !run) begin
                        if (!ovf) begin
                            // Khởi động chu kỳ tuần tự: Chốt 27 bit dữ liệu đầu vào
                            run <= 1'b1;
                            cnt <= 5'd0;
                            d   <= 32'd0;
                            b   <= x[26:0];
                        end
                    end else if (run) begin
                        // Bước chuyển dịch tiếp theo
                        d   <= d_n;
                        b   <= {b[25:0], 1'b0};
                        cnt <= cnt + 5'd1;
                        if (last) begin
                            run <= 1'b0; // Hoàn thành 27 bước, trả về trạng thái rảnh
                        end
                    end
                end
            end
        end 
    endgenerate

endmodule
