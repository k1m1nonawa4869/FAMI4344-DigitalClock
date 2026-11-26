// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     muldiv.v — Đơn vị Nhân / Chia Số Học (Multiplier & 32-Step Divider)
// CHUYÊN ĐỀ KTMT: Chương 03: Số học máy tính (Thuật toán chia Restoring 32 chu kỳ)
// VAI TRÒ:        Khối Xử Lý Phép Tính Nhân & Chia Phần Cứng
// MÔ TẢ:          - Phép nhân (mul): Mạch nhân tổ hợp 1 chu kỳ, lấy 32 bit thấp.
//                 - Phép chia (div): Thuật toán chia khôi phục số dư (Restoring Division)
//                   32 bước tuần tự trên cặp thanh ghi [A, Q], quản lý cờ busy/done và
//                   cập nhật cặp thanh ghi đặc biệt HI (số dư) / LO (thương số).
// ============================================================================

`timescale 1ns/1ps

module muldiv (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,     // Xung nhịp hệ thống (System Clock)
    input  wire        rst,     // Tín hiệu Reset đồng bộ mức cao (Active-high Reset)
    input  wire        ce,      // Clock Enable (1 chu kỳ CPU: G1 theo cạnh pha A; G2 theo cpu_ce)
    input  wire        start,   // Xung khởi động phép chia (1 chu kỳ CPU khi ce = 1 và không busy)
    input  wire [31:0] a,       // Số bị chia (Dividend) - lấy từ thanh ghi rs
    input  wire [31:0] b,       // Số chia (Divisor) - lấy từ thanh ghi rt
    output wire [31:0] mul_y,   // Kết quả phép nhân 32 bit thấp của a * b
    output wire        busy,    // Báo trạng thái bộ chia đang bận tính toán 32 chu kỳ (Pipeline stall)
    output wire        done,    // Báo kết quả phép chia đã hoàn tất, sẵn sàng ghi vào HI/LO
    output reg  [31:0] lo,      // Thanh ghi LO: Lưu trữ Thương số (Quotient)
    output reg  [31:0] hi,      // Thanh ghi HI: Lưu trữ Số dư (Remainder)
    output reg         dz       // Cờ báo lỗi chia cho số 0 (Divide-by-Zero Flag)
);

    // ------------------------------------------------------------------------
    // 1. PHÉP NHÂN TỔ HỢP 32-BIT (COMBINATIONAL MULTIPLIER)
    // ------------------------------------------------------------------------
    // Trong kiến trúc MIPS, lệnh `mul` lấy 32 bit thấp của tích a * b.
    // Đối với 32 bit thấp, phép nhân số có dấu và không dấu cho ra cùng chuỗi bit nhị phân.
    assign mul_y = a * b;

    // ------------------------------------------------------------------------
    // 2. NGUYÊN LÝ THUẬT TOÁN CHIA KHÔI PHỤC SỐ DƯ (RESTORING DIVISION ALGORITHM)
    // ------------------------------------------------------------------------
    // Thuật toán chia phần cứng mô phỏng tương tự phép chia đặt tính trên giấy:
    // Cặp thanh ghi ghép đôi 64-bit [A, Q]:
    //   - A (rem): Thanh ghi Số dư 32-bit (khởi đầu = 0).
    //   - Q (quo): Thanh ghi chứa Số bị chia (khởi đầu = |a|).
    //   - M (dvs): Thanh ghi Số chia 32-bit = |b|.
    //
    // Mỗi bước trong 32 chu kỳ thực hiện 3 thao tác:
    //   Bước 1: Dịch trái toàn bộ cặp [A, Q] đi 1 bit:
    //           Bit cao nhất của Q (quo[31]) được đẩy vào bit thấp nhất của A.
    //   Bước 2: Thử trừ: trial = A - M.
    //   Bước 3: Kiểm tra dấu:
    //           - Nếu trial >= 0 (fits = 1, phép trừ thành công):
    //             A nhận giá trị mới (A = trial), gán bit thương số Q[0] = 1.
    //           - Nếu trial < 0 (fits = 0, phép trừ thất bại):
    //             Khôi phục (Restore) lại số dư cũ: A giữ nguyên, gán bit thương số Q[0] = 0.
    //
    // Sau đúng 32 chu kỳ, Q chứa giá trị tuyệt đối của thương số, A chứa giá trị tuyệt đối của số dư.
    // Quy tắc phục hồi dấu (Sign Correction) chuẩn MIPS:
    //   - Thương số âm nếu a và b khác dấu: neg_q = a[31] ^ b[31].
    //   - Số dư luôn mang cùng dấu với số bị chia a: neg_r = a[31].
    // ------------------------------------------------------------------------

    reg        run;    // Cờ trạng thái FSM: 1 = đang chạy vòng lặp 32 chu kỳ
    reg [4:0]  cnt;    // Bộ đếm chu kỳ: từ 0 đến 31 (đủ 32 bước)
    reg [31:0] rem;    // Thanh ghi Số dư A (Remainder)
    reg [31:0] quo;    // Thanh ghi Thương số/Số bị chia Q (Quotient)
    reg [31:0] dvs;    // Thanh ghi Số chia M (Divisor: |b|)
    reg        neg_q;  // Cờ nhớ dấu của thương số
    reg        neg_r;  // Cờ nhớ dấu của số dư

    // Dịch trái cặp [rem, quo] đi 1 bit (ghép thành 33 bit để thử trừ không mất dấu)
    wire [32:0] rem_sh = {rem, quo[31]};
    // Phép thử trừ với số chia: trial = rem_sh - dvs (33 bit có dấu)
    wire [32:0] trial  = rem_sh - {1'b0, dvs};
    // Nếu bit thứ 32 bằng 0 nghĩa là trial không âm (phép trừ thành công)
    wire        fits   = ~trial[32];
    // Khôi phục số dư: nếu fits=1 thì lấy hiệu, nếu không thì giữ nguyên số dư cũ
    wire [31:0] rem_n  = fits ? trial[31:0] : rem_sh[31:0];
    // Đẩy bit thương mới vào hàng đơn vị của quo
    wire [31:0] quo_n  = {quo[30:0], fits};

    // Kiểm tra trường hợp đặc biệt: Chia cho 0 (Divide-by-zero)
    wire div0  = (b == 32'd0);
    // Bước cuối cùng của thuật toán chia (bước 31)
    wire last  = run && (cnt == 5'd31);

    // Tín hiệu bận: CPU phải stall giữ nguyên trạng thái pipeline khi busy = 1
    assign busy = run;
    // Tín hiệu hoàn thành: Bật ở chu kỳ chia cho 0 hoặc chu kỳ bước thứ 32 kết thúc
    assign done = ce && ((start && !run && div0) || last);

    // ------------------------------------------------------------------------
    // MÁY TRẠNG THÁI TUẦN TỰ (SEQUENTIAL CONTROL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            run   <= 1'b0;
            cnt   <= 5'd0;
            rem   <= 32'd0;
            quo   <= 32'd0;
            dvs   <= 32'd0;
            neg_q <= 1'b0;
            neg_r <= 1'b0;
            lo    <= 32'd0;
            hi    <= 32'd0;
            dz    <= 1'b0;
        end else if (ce) begin
            if (start && !run) begin
                if (div0) begin
                    // Ngoại lệ chia cho 0: Xử lý ngay lập tức trong 1 chu kỳ clock, không chạy 32 bước
                    lo <= 32'd0;
                    hi <= a;
                    dz <= 1'b1;
                end else begin
                    // Khởi động phép chia: Lấy trị tuyệt đối toán hạng và ghi nhớ dấu ban đầu
                    run   <= 1'b1;
                    cnt   <= 5'd0;
                    rem   <= 32'd0;
                    quo   <= a[31] ? -a : a;  // |a| (trường hợp đặc biệt 0x80000000 vẫn giữ đúng độ lớn)
                    dvs   <= b[31] ? -b : b;  // |b|
                    neg_q <= a[31] ^ b[31];   // Thương âm nếu hai số khác dấu
                    neg_r <= a[31];           // Dư mang cùng dấu với số bị chia a
                end
            end else if (run) begin
                // Cập nhật kết quả bước chia hiện tại
                rem <= rem_n;
                quo <= quo_n;
                cnt <= cnt + 5'd1;

                if (last) begin
                    // Đã xong chu kỳ thứ 32: Hoàn tất thuật toán, hiệu chỉnh dấu và nạp HI / LO
                    run <= 1'b0;
                    lo  <= neg_q ? -quo_n : quo_n; // Hiệu chỉnh dấu thương số
                    hi  <= neg_r ? -rem_n : rem_n; // Hiệu chỉnh dấu số dư
                    dz  <= 1'b0;
                end
            end
        end
    end

endmodule
