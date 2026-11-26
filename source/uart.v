// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     uart.v — Bộ Truyền Thông Nối Tiếp Bất Đồng Bộ UART 8N1
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra, Truyền Thông Nối Tiếp & Lấy Mẫu Giữa Bit
// VAI TRÒ:        Khối Giao Tiếp UART 115200 Baud & Hàng Đợi FIFO 64 Byte
// MÔ TẢ:          Module truyền thông nối tiếp bất đồng bộ UART chuẩn 8N1:
//                 - Khung truyền: 1 Start bit, 8 Data bits (LSB first), No parity, 1 Stop bit.
//                 - Tốc độ baud: Mặc định 115200 bps ở xung nhịp 50 MHz (G_BIT = 434 chu kỳ/bit).
//                 - Bộ nhận RX: Đồng bộ hóa 2-FF, xác thực bit Start tại giữa bit, lấy mẫu giữa bit,
//                   và phát hiện lỗi khung (Framing Error).
//                 - Hàng đợi RX FIFO 64 byte và bộ đệm phát TX kép (Double-buffered TX) phát liền mạch.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Chuẩn Giao Thức Khung Truyền UART 8N1 (8N1 Protocol):
//    - Không có đường clock đi kèm, bộ thu và phát thỏa thuận trước tốc độ truyền (Baud Rate).
//    - Đường truyền ở trạng thái rảnh (Idle) ở mức logic 1 (Mark state).
//    - Cấu trúc khung truyền 1 byte (tổng 10 bit):
//        + 1 bit Start (mức 0): Báo hiệu cho bộ nhận biết bắt đầu truyền một byte mới.
//        + 8 bit dữ liệu: Bit có trọng số nhỏ nhất (LSB - bit 0) truyền trước, bit cao (MSB - bit 7) sau.
//        + 0 bit chẵn lẻ (No parity): Không chèn bit kiểm tra dư thừa.
//        + 1 bit Stop (mức 1): Đưa đường truyền trở lại mức nghỉ, cho phép phát hiện lỗi khung.
//
// 2. Tính Toán Chu Kỳ Tốc Độ Baud (Baud Rate Timing Calculation):
//    - Tần số xung nhịp hệ thống SoC: f_clk = 50 MHz (chu kỳ T = 20 ns).
//    - Tốc độ truyền thông tiêu chuẩn: 115.200 bit/giây (bps).
//    - Số chu kỳ xung nhịp cho mỗi bit dữ liệu:
//          G_BIT = 50.000.000 / 115.200 = 434,027 chu kỳ clock.
//      Lấy tròn: G_BIT = 434 chu kỳ/bit.
//    - Sai số tần số thực tế: |434 - 434,027| / 434,027 = 0,006% << 2% (độ chính xác hoàn hảo).
//
// 3. Cơ Chế Lọc Nhiễu & Lấy Mẫu Giữa Bit (Mid-Bit Sampling & Glitch Rejection):
//    - Tín hiệu `rx` đi qua 2 tầng Flip-Flop (r1, r2) chống hiện tượng bán ổn định (Metastability).
//    - Phát hiện cạnh xuống (Falling Edge) từ 1 xuống 0 trên tín hiệu đã đồng bộ.
//    - Xác thực bit Start (Half-bit Verification):
//        + Bộ nhận đếm đúng HALF = G_BIT / 2 = 217 chu kỳ rồi kiểm tra lại mức tín hiệu.
//        + Nếu rx = 0: Xác nhận là sườn Start thực sự, chuyển sang máy trạng thái nhận dữ liệu R_DATA.
//        + Nếu rx = 1: Xác định là xung gai nhiễu tức thời (glitch), lập tức hủy bỏ và quay lại R_IDLE.
//    - Lấy mẫu giữa bit: Tại điểm chính giữa mỗi bit dữ liệu (chu kỳ rcnt == BIT - 1), biên độ tín hiệu
//      đạt độ ổn định cực đại, cách xa sườn chuyển tiếp, triệt tiêu sai số trôi pha xung nhịp.
//    - Phát hiện lỗi khung (Framing Error): Tại vị trí bit Stop, nếu tín hiệu nhận được là 0 (thay vì 1),
//      cờ `ferr` được bật và byte lỗi bị hủy bỏ không đưa vào FIFO.
//
// 4. Bộ Phát TX Đệm Kép Liền Mạch (Double-Buffered TX):
//    - Gồm thanh ghi đệm `tbuf` và thanh ghi dịch `tsh` (9-bit).
//    - CPU ghi byte vào `tbuf` khi cờ `TX_READY` bật.
//    - Ngay khi `tsh` phát xong bit cuối, nếu `tbuf` đang có dữ liệu, byte mới được nạp tức thì
//      vào `tsh` mà không chèn khoảng nghỉ (Idle gaps), đạt băng thông phát tối đa 10 bit/byte.
//
// 5. Hàng Đợi RX FIFO 64 Byte & Quản Lý Cờ Lỗi W1C:
//    - Hàng đợi FIFO 64 byte giúp CPU không bị mất dữ liệu khi đang bận thực thi ngắt khác.
//    - Các cờ lỗi dính (Sticky flags: RX_OVF, FRAME_ERR, TX_DROP) tuân theo cơ chế Write-1-to-Clear (W1C).
//      Nếu cùng chu kỳ CPU ghi lệnh xóa cờ mà có sự kiện lỗi mới xuất hiện, sự kiện mới luôn thắng.
// ============================================================================

`timescale 1ns/1ps

module uart #(
    parameter G_BIT = 434               // Số chu kỳ clock cho mỗi bit UART (mặc định 434 @ 50 MHz = 115200 baud)
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,             // Xung nhịp hệ thống 50 MHz
    input  wire        rst,             // Reset đồng bộ mức cao (Active-high Reset)
    input  wire        rx,              // Đường nhận dữ liệu nối tiếp RX (bất đồng bộ, nghỉ = 1)
    output reg         tx,              // Đường phát dữ liệu nối tiếp TX (nghỉ = 1)
    
    // Giao diện Bus MMIO
    input  wire [7:0]  bus_addr,        // Địa chỉ thanh ghi ngoại vi
    input  wire [31:0] bus_wdata,       // Dữ liệu ghi từ CPU
    input  wire        bus_we,          // Tín hiệu ghi MMIO (Write Enable)
    input  wire        bus_re,          // Tín hiệu đọc MMIO (Read Enable)
    output reg  [31:0] bus_rdata,       // Dữ liệu đọc trả về cho CPU
    
    // Tín hiệu ngắt sự kiện
    output wire        rx_ev,           // Xung 1 chu kỳ khi nhận thành công 1 byte vào FIFO (ngắt bit 6)
    output wire        tx_ev            // Xung 1 chu kỳ khi bộ đệm phát vừa trống (ngắt bit 7)
);

    // ------------------------------------------------------------------------
    // ĐỊA CHỈ THANH GHI NGOẠI VI (MMIO REGISTER ADDRESS MAP)
    // ------------------------------------------------------------------------
    localparam A_STATUS = 8'h50,        // 0x50: Thanh ghi trạng thái & điều khiển (R/W1C)
               A_RX     = 8'h54,        // 0x54: Cổng đọc FIFO nhận (Read-Only, đọc tự động pop)
               A_TX     = 8'h58;        // 0x58: Cổng ghi dữ liệu phát (Write-Only)

    localparam [15:0] BIT  = G_BIT,
                      HALF = G_BIT / 2;

    // ------------------------------------------------------------------------
    // KHỐI PHÁT DỮ LIỆU NỐI TIẾP (TRANSMITTER - TX)
    // ------------------------------------------------------------------------
    reg [7:0]  tbuf;                    // Bộ đệm byte chờ phát
    reg        tfull;                   // Trạng thái bộ đệm: 1 = Đang có byte chờ phát
    reg [8:0]  tsh;                     // Thanh ghi dịch phát: {Stop_bit, Data[7:0]}, bit 0 ra trước
    reg [3:0]  tleft;                   // Số bit còn lại của khung truyền (0 = Rảnh)
    reg [15:0] tcnt;                    // Bộ đếm chu kỳ clock trong 1 bit

    wire w_tx   = bus_we && (bus_addr == A_TX);
    // Nạp dữ liệu từ bộ đệm sang thanh ghi dịch ngay khi rảnh hoặc ở cạnh cuối của bit Stop
    wire t_load = tfull && ((tleft == 4'd0) || ((tleft == 4'd1) && (tcnt == BIT - 16'd1)));
    assign tx_ev = t_load;              // Báo ngắt khi bộ đệm vừa được giải phóng

    // ------------------------------------------------------------------------
    // KHỐI NHẬN DỮ LIỆU NỐI TIẾP (RECEIVER - RX)
    // ------------------------------------------------------------------------
    reg        r1, r2, r2q;             // Đồng bộ 2 Flip-Flop + thanh ghi trễ phát hiện sườn xuống
    reg [1:0]  rst_st;                  // Trạng thái máy nhận: 0=IDLE, 1=START, 2=DATA
    reg [15:0] rcnt;                    // Bộ đếm chu kỳ clock trong 1 bit
    reg [3:0]  rbit;                    // Chỉ số bit đang lấy mẫu: 0..7 dữ liệu, 8 = bit Stop
    reg [7:0]  rsh;                     // Thanh ghi dịch gom 8 bit dữ liệu nhận
    
    // Hàng đợi FIFO nhận 64 byte
    reg [7:0]  fifo [0:63];             // Bộ nhớ RAM FIFO 64 byte
    reg [5:0]  rp, wp;                  // Con trỏ đọc và ghi FIFO
    reg [6:0]  n;                       // Số lượng byte hiện có trong FIFO (0 .. 64)
    
    // Các cờ trạng thái lỗi
    reg        ovf;                     // Tràn hàng đợi RX FIFO
    reg        ferr;                    // Lỗi khung truyền (Stop bit != 1)
    reg        drop;                    // Ghi đè khi bộ đệm TX đang đầy

    localparam R_IDLE  = 2'd0,
               R_START = 2'd1,
               R_DATA  = 2'd2;

    // Điều kiện nhận xong bit Stop hợp lệ
    wire r_done = (rst_st == R_DATA) && (rcnt == BIT - 16'd1) && (rbit == 4'd8);
    wire r_good = r_done && r2;                                              // Bit Stop = 1: Khung hợp lệ
    wire pop    = bus_re && (bus_addr == A_RX) && (n != 7'd0);               // CPU đọc 1 byte ra khỏi FIFO
    wire push   = r_good && ((n != 7'd64) || pop);                           // Nhận byte mới vào FIFO
    assign rx_ev = push;                                                     // Báo ngắt khi có byte mới

    wire w_st = bus_we && (bus_addr == A_STATUS);

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ (SEQUENTIAL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            tx        <= 1'b1;
            tfull     <= 1'b0;
            tleft     <= 4'd0;
            tcnt      <= 16'd0;
            tsh       <= 9'h1FF;
            tbuf      <= 8'd0;
            r1        <= 1'b1;
            r2        <= 1'b1;
            r2q       <= 1'b1;
            rst_st    <= R_IDLE;
            rcnt      <= 16'd0;
            rbit      <= 4'd0;
            rsh       <= 8'd0;
            rp        <= 6'd0;
            wp        <= 6'd0;
            n         <= 7'd0;
            ovf       <= 1'b0;
            ferr      <= 1'b0;
            drop      <= 1'b0;
            bus_rdata <= 32'd0;
        end else begin
            // ----------------------------------------------------------------
            // 1. TIẾN TRÌNH PHÁT DỮ LIỆU (TX PROCESS)
            // ----------------------------------------------------------------
            if (w_tx) begin
                if (!tfull) begin
                    tbuf  <= bus_wdata[7:0];
                    tfull <= 1'b1;
                end
            end

            if (t_load) begin
                tfull <= 1'b0;
                tx    <= 1'b0;                 // Phát bit Start = 0
                tsh   <= {1'b1, tbuf};         // Nạp 8 bit dữ liệu + 1 bit Stop (mức 1)
                tleft <= 4'd10;                // Khung truyền gồm 10 bit
                tcnt  <= 16'd0;
            end else if (tleft != 4'd0) begin
                if (tcnt == BIT - 16'd1) begin
                    tcnt  <= 16'd0;
                    tleft <= tleft - 4'd1;
                    tx    <= (tleft == 4'd1) ? 1'b1 : tsh[0]; // Bit cuối trả về mức 1 nghỉ
                    tsh   <= {1'b1, tsh[8:1]};                // Dịch bit tiếp theo ra LSB
                end else begin
                    tcnt <= tcnt + 16'd1;
                end
            end

            // ----------------------------------------------------------------
            // 2. TIẾN TRÌNH NHẬN DỮ LIỆU (RX PROCESS)
            // ----------------------------------------------------------------
            r1  <= rx;
            r2  <= r1;
            r2q <= r2;

            case (rst_st)
                R_IDLE: begin
                    // Phát hiện cạnh xuống: Chuyển sang kiểm tra bit Start
                    if (r2q && !r2) begin
                        rst_st <= R_START;
                        rcnt   <= 16'd0;
                    end
                end

                R_START: begin
                    // Kiểm tra tại giữa bit Start (HALF): Nếu còn mức 0 mới là Start thật
                    if (rcnt == HALF - 16'd1) begin
                        rst_st <= r2 ? R_IDLE : R_DATA;
                        rcnt   <= 16'd0;
                        rbit   <= 4'd0;
                    end else begin
                        rcnt <= rcnt + 16'd1;
                    end
                end

                default: begin // R_DATA
                    // Lấy mẫu tại giữa mỗi bit dữ liệu và bit Stop
                    if (rcnt == BIT - 16'd1) begin
                        rcnt <= 16'd0;
                        if (rbit == 4'd8) begin
                            rst_st <= R_IDLE; // Hoàn tất bit Stop: Quay về trạng thái rảnh
                        end else begin
                            rsh    <= {r2, rsh[7:1]}; // Dịch bit nhận vào MSB của thanh ghi gom
                            rbit   <= rbit + 4'd1;
                        end
                    end else begin
                        rcnt <= rcnt + 16'd1;
                    end
                end
            endcase

            // ----------------------------------------------------------------
            // 3. QUẢN LÝ HÀNG ĐỢI RX FIFO 64 BYTE
            // ----------------------------------------------------------------
            if (push) begin
                fifo[wp] <= rsh;
                wp       <= wp + 6'd1;
            end

            if (pop) begin
                rp <= rp + 6'd1;
            end

            n <= n + {6'd0, push} - {6'd0, pop};

            // ----------------------------------------------------------------
            // 4. QUẢN LÝ CỜ TRẠNG THÁI LỖI (STICKY FLAGS VỚI W1C)
            // ----------------------------------------------------------------
            // Sự kiện phát sinh lỗi mới luôn chiếm quyền ưu tiên hơn lệnh CPU ghi xóa
            ovf  <= (r_good && !push)  || (ovf  && !(w_st && bus_wdata[1]));
            ferr <= (r_done && !r2)    || (ferr && !(w_st && bus_wdata[3]));
            drop <= (w_tx && tfull)    || (drop && !(w_st && bus_wdata[4]));

            // ----------------------------------------------------------------
            // 5. GIAO DIỆN ĐỌC BUS MMIO
            // ----------------------------------------------------------------
            if (bus_re) begin
                case (bus_addr)
                    A_STATUS: begin
                        // Định dạng thanh ghi A_STATUS:
                        // [31:15] = 0
                        // [14:8]  = n        (Số byte hiện có trong RX FIFO, 0..64)
                        // [7:5]   = 0
                        // [4]     = drop     (Cờ ghi tràn bộ đệm TX)
                        // [3]     = ferr     (Cờ lỗi khung truyền RX)
                        // [2]     = !tfull   (TX_READY: Bộ đệm TX sẵn sàng nhận byte mới)
                        // [1]     = ovf      (Cờ tràn hàng đợi RX FIFO)
                        // [0]     = n != 0   (RX_READY: Có ít nhất 1 byte sẵn sàng để đọc)
                        bus_rdata <= {17'd0, n, 3'd0, drop, ferr, !tfull, ovf, (n != 7'd0)};
                    end

                    A_RX: begin
                        // Đọc byte từ đỉnh RX FIFO: Bit [31] = 1 báo dữ liệu hợp lệ
                        bus_rdata <= (n != 7'd0) ? {1'b1, 23'd0, fifo[rp]} : 32'd0;
                    end

                    default: begin
                        bus_rdata <= 32'd0;
                    end
                endcase
            end
        end
    end

    // Khử cảnh báo linter đối với các bit bus không sử dụng
    wire unused_ok = &{1'b0, bus_wdata[31:8], bus_wdata[2], bus_wdata[0]};

endmodule
