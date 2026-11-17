// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     stopwatch_core.v — Khối Bấm Giờ Thể Thao & Chốt Vòng Phần Cứng 0-ns
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra, Bộ Định Thời & Bắt Sự Kiện Phần Cứng
// VAI TRÒ:        Bộ Bấm Giờ Chính Xác Cao & Hàng Đợi 8 Lap (Hardware Capture Stopwatch)
// MÔ TẢ:          Module bấm giờ thể thao chính xác đến 1 ms với bộ chia tần số riêng,
//                 cơ chế chốt sự kiện phần cứng 0-ns trễ (Hardware Event Capture),
//                 và hàng đợi tròn (Circular FIFO) 8 phần tử lưu thời gian từng vòng (Lap).
//                 Hỗ trợ cơ chế bão hòa cực đại 99:59:59.999 chống quay vòng sai lệch.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Tại sao cần bộ chia phân số độc lập (Dedicated Prescaler / Timebase)?
//    - Nếu dùng chung xung nhịp tick_ms toàn cục của hệ thống SoC, tại thời điểm người
//      dùng nhấn nút Bắt đầu (Start), pha của bộ đếm 1 ms hệ thống đang ở vị trí ngẫu nhiên
//      trong khoảng 0 .. 49.999 chu kỳ clock.
//    - Hệ quả: mili-giây đầu tiên có thể bị co ngắn bất thường (sai số ngẫu nhiên ±1 ms).
//    - Giải pháp: Khối Stopwatch tích hợp một bộ chia `timebase` chuyên dụng bên trong:
//        + Khi nhận lệnh Reset: Bộ chia xóa sạch pha tích lũy về 0 (clr = w_reset).
//        + Bộ chia chỉ cho phép chạy khi RUN = 1 (en = run).
//      Do đó, chính xác sau 50.000 chu kỳ xung nhịp kể từ thời khắc bấm nút, mili-giây
//      đầu tiên mới được ghi nhận. Tổng thời gian chạy qua C chu kỳ luôn đạt floor(C / G_N).
//
// 2. Nguyên lý Bắt sự kiện Phần cứng 0-ns (0-ns Hardware Event Capture):
//    - So sánh với cơ chế phần mềm truyền thống (Software Polling / Interrupt):
//        + Phần mềm: Nút bấm kích hoạt ngắt, CPU lưu ngữ cảnh (context switch), nhảy vào
//          trình phục vụ ngắt (ISR), đọc giá trị bộ đếm qua bus. Độ trễ trôi có thể lên đến 1,36 ms.
//        + Bắt sự kiện Phần cứng (SRC = 1): Tín hiệu nút bấm A (Start/Stop) và B (Lap)
//          từ khối khử rung được đưa trực tiếp vào logic phần cứng của Stopwatch.
//          Ngay tại chu kỳ xung nhịp phát hiện cạnh nhấn (hw_lap), giá trị bộ đếm `val`
//          được chốt tức thời vào thanh ghi hàng đợi FIFO trong đúng chu kỳ đó (độ trễ Delta T = 0 ns).
//
// 3. Cấu trúc Hàng đợi tròn 8 phần tử (8-Entry Circular FIFO Ring Buffer):
//    - Mảng thanh ghi `fifo[0..7]` (mỗi phần tử 29-bit) lưu trữ các mốc thời gian Lap.
//    - Quản lý bằng con trỏ ghi `wp` (3-bit), con trỏ đọc `rp` (3-bit) và bộ đếm số lượng `cnt` (4-bit, 0..8).
//    - Hỗ trợ xử lý đọc/ghi đồng thời an toàn:
//        `accept = push && (cnt != 8 || pop);`
//      Nếu FIFO đầy mà CPU đồng thời phát lệnh đọc lấy phần tử ra (pop), lap mới vẫn được nhận an toàn.
//    - Cơ chế bảo vệ: Khi FIFO đầy (cnt == 8) mà có lap mới tới mà không pop, cờ `lap_ovf` bật và lap mới bị bỏ.
//
// 4. Cơ chế Bão hòa Giới hạn Thời gian (Saturation vs Rollover):
//    - Giới hạn cực đại: G_SW_MAX = 359.999.999 ms (tương đương 99 giờ 59 phút 59 giây 999 ms).
//    - Khi đạt đến giá trị này, cờ `ovf` được kích hoạt và bộ đếm dừng lại (saturation),
//      tuyệt đối không quay vòng về 0 để tránh làm sai lệch kết quả thi đấu thể thao.
//
// 5. Giải quyết xung đột điều khiển (Hazard & Priority Resolution):
//    - Khi CPU ghi lệnh chuyển chế độ SRC = 0 trong cùng chu kỳ nút bấm vật lý nhấn:
//      Lệnh ghi của CPU chiếm quyền ưu tiên cao hơn (bỏ qua xung nút, không phát sự kiện SW_CAPTURE).
//    - Lệnh Reset (w_reset) chiếm ưu tiên tối thượng, hủy bỏ mọi thao tác lưu lap cùng chu kỳ.
// ============================================================================

`timescale 1ns/1ps

module stopwatch #(
    parameter G_N      = 50000,         // Số chu kỳ clock / 1 ms (trên FPGA = 50.000; mô phỏng = 50)
    parameter G_SW_MAX = 359999999      // Thời gian đo cực đại: 99:59:59.999 (ms)
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire               clk,      // Xung nhịp hệ thống 50 MHz
    input  wire               rst,      // Reset đồng bộ mức cao (Active-high Reset)
    input  wire signed [31:0] cal,      // Giá trị hiệu chỉnh tần số ppm cho bộ chia riêng
    
    // Đường tín hiệu nút bấm phần cứng bắt sườn trực tiếp (0-ns latency)
    input  wire               press_a,  // Xung sườn nút A: Bật/Tắt bấm giờ (Start / Stop toggle)
    input  wire               press_b,  // Xung sườn nút B: Chốt vòng (Lap capture) khi đang chạy
    
    // Giao diện Bus MMIO
    input  wire [7:0]         bus_addr, // Địa chỉ thanh ghi ngoại vi
    input  wire [31:0]        bus_wdata,// Dữ liệu ghi từ CPU
    input  wire               bus_we,   // Tín hiệu ghi MMIO (Write Enable)
    input  wire               bus_re,   // Tín hiệu đọc MMIO (Read Enable)
    output reg  [31:0]        bus_rdata,// Dữ liệu đọc trả về cho CPU
    
    // Tín hiệu ngắt sự kiện phần cứng
    output wire               capture   // Xung báo sự kiện SW_CAPTURE (kết nối tới IRQ Controller bit 4)
);

    // ------------------------------------------------------------------------
    // ĐỊA CHỈ THANH GHI NGOẠI VI (MMIO REGISTER ADDRESS MAP)
    // ------------------------------------------------------------------------
    localparam A_CTRL = 8'h1C,          // 0x1C: Thanh ghi điều khiển & trạng thái (R/W)
               A_VAL  = 8'h20,          // 0x20: Thanh ghi đọc thời gian hiện tại [28:0] (Read-Only)
               A_LAP  = 8'h24;          // 0x24: Cổng đọc FIFO Lap [28:0] (Đọc sẽ pop 1 phần tử khỏi FIFO)

    // ------------------------------------------------------------------------
    // THANH GHI VÀ TÍN HIỆU NỘI BỘ (INTERNAL REGISTERS & SIGNALS)
    // ------------------------------------------------------------------------
    reg [28:0] val;                     // Bộ đếm thời gian bấm giờ (đơn vị: mili-giây, 0 .. 359.999.999)
    reg        run;                     // Trạng thái đang đếm: 1 = Running, 0 = Stopped
    reg        src;                     // Nguồn điều khiển: 1 = Nút bấm phần cứng trực tiếp, 0 = CPU ghi MMIO
    reg        ovf;                     // Cờ bão hòa cực đại 99:59:59.999
    reg        lap_ovf;                 // Cờ báo tràn hàng đợi Lap (FIFO full mà vẫn chốt thêm)
    
    reg [28:0] fifo [0:7];              // Mảng 8 thanh ghi lưu trữ giá trị Lap
    reg [2:0]  rp, wp;                  // Con trỏ đọc (Read Pointer) và con trỏ ghi (Write Pointer)
    reg [3:0]  cnt;                     // Số lượng Lap hiện có trong hàng đợi (0 .. 8)

    // ------------------------------------------------------------------------
    // TÍN HIỆU ĐIỀU KHIỂN & BỘ CHIA PHÂN SỐ RIÊNG (DEDICATED PRESCALER)
    // ------------------------------------------------------------------------
    wire wr_ctrl = bus_we && (bus_addr == A_CTRL);
    wire w_reset = wr_ctrl && bus_wdata[1];                     // Lệnh xóa thời gian và FIFO về 0
    wire w_cpu   = wr_ctrl && !bus_wdata[2];                    // CPU ghi với SRC=0: trực tiếp điều khiển RUN/LAP
    wire tick;                                                  // Xung nhịp 1 ms sinh từ bộ chia riêng

    // Bộ chia timebase chuyên dụng: Khởi tạo pha chuẩn xác, không bị lệch pha với hệ thống
    timebase #(.G_N(G_N)) u_div (
        .clk(clk),
        .rst(rst),
        .clr(w_reset),
        .en(run),
        .cal(cal),
        .tick(tick)
    );

    // ------------------------------------------------------------------------
    // LOGIC BẮT SỰ KIỆN PHẦN CỨNG 0-NS (HARDWARE EVENT CAPTURE LOGIC)
    // ------------------------------------------------------------------------
    // Nút A đảo trạng thái chạy/dừng khi ở chế độ phần cứng (SRC=1) và không có lệnh CPU ghi can thiệp
    wire hw_toggle = src && press_a && !w_cpu;
    
    // Nút B chốt 1 lap khi đang chạy ở chế độ phần cứng (SRC=1) và không có lệnh reset
    wire hw_lap    = src && press_b && run && !w_cpu && !w_reset;
    
    // Điều kiện có yêu cầu đẩy (push) 1 lap vào FIFO: từ nút bấm phần cứng hoặc do CPU ghi bit [5]
    wire push      = hw_lap || (w_cpu && !w_reset && bus_wdata[5]);
    
    // Điều kiện rút (pop) 1 lap ra khỏi FIFO: CPU đọc địa chỉ A_LAP khi FIFO không rỗng
    wire pop       = bus_re && (bus_addr == A_LAP) && (cnt != 4'd0);
    
    // Cho phép nhận lap mới vào FIFO: Khi FIFO chưa đầy, hoặc đầy nhưng đồng thời có lệnh pop
    wire accept    = push && ((cnt != 4'd8) || pop);
    
    // Tín hiệu ngắt capture báo cho CPU biết có sự kiện bấm nút cứng A hoặc B
    assign capture = hw_toggle || hw_lap;

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ (SEQUENTIAL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            val       <= 29'd0;
            run       <= 1'b0;
            src       <= 1'b0;
            ovf       <= 1'b0;
            lap_ovf   <= 1'b0;
            rp        <= 3'd0;
            wp        <= 3'd0;
            cnt       <= 4'd0;
            bus_rdata <= 32'd0;
        end else begin
            // ----------------------------------------------------------------
            // 1. TIẾN TRÌNH ĐẾM THỜI GIAN (TIMER ACCUMULATOR)
            // ----------------------------------------------------------------
            if (w_reset) begin
                val <= 29'd0;
                ovf <= 1'b0;
            end else if (tick) begin
                if (val == G_SW_MAX) begin
                    ovf <= 1'b1;                                // Bão hòa khi đạt cực đại, không đếm tiếp
                end else begin
                    val <= val + 29'd1;
                end
            end

            // ----------------------------------------------------------------
            // 2. ĐIỀU KHIỂN CHẾ ĐỘ NGUỒN (SRC) VÀ CHẠY/DỪNG (RUN)
            // ----------------------------------------------------------------
            if (wr_ctrl)        src <= bus_wdata[2];
            if (w_cpu)          run <= bus_wdata[0];
            else if (hw_toggle) run <= !run;                    // Nút cứng A đảo trạng thái chạy/dừng tức thì

            // ----------------------------------------------------------------
            // 3. QUẢN LÝ HÀNG ĐỢI FIFO 8 LAP
            // ----------------------------------------------------------------
            if (w_reset) begin
                rp      <= 3'd0;
                wp      <= 3'd0;
                cnt     <= 4'd0;
                lap_ovf <= 1'b0;
            end else begin
                if (accept) begin
                    fifo[wp] <= val;                            // Chốt tức thời giá trị thời gian hiện tại vào FIFO
                    wp       <= wp + 3'd1;
                end else if (push) begin
                    lap_ovf  <= 1'b1;                           // Hàng đợi đầy: bật cờ cảnh báo tràn lap
                end

                if (pop) begin
                    rp <= rp + 3'd1;                            // Tăng con trỏ đọc khi CPU đọc A_LAP
                end

                // Cập nhật số lượng phần tử có trong FIFO (hỗ trợ push và pop đồng thời)
                cnt <= cnt + {3'd0, accept} - {3'd0, pop};
            end

            // ----------------------------------------------------------------
            // 4. GIAO DIỆN ĐỌC BUS MMIO (BUS READ LOGIC)
            // ----------------------------------------------------------------
            if (bus_re) begin
                case (bus_addr)
                    A_CTRL: begin
                        // Định dạng thanh ghi A_CTRL:
                        // [31:12] = 0
                        // [11:8]  = cnt (số lap trong FIFO, 0..8)
                        // [7:5]   = 0
                        // [4]     = lap_ovf (cờ tràn FIFO)
                        // [3]     = ovf (cờ bão hòa cực đại)
                        // [2]     = src (chế độ điều khiển phần cứng)
                        // [1]     = 0 (bit reset luôn đọc về 0)
                        // [0]     = run (trạng thái đang chạy)
                        bus_rdata <= {20'd0, cnt, 3'd0, lap_ovf, ovf, src, 1'b0, run};
                    end
                    A_VAL: begin
                        // Đọc thời gian bấm giờ hiện tại (ms)
                        bus_rdata <= {3'd0, val};
                    end
                    A_LAP: begin
                        // Đọc lap từ đỉnh FIFO: Bit [31]=1 báo dữ liệu hợp lệ; nếu FIFO rỗng trả về 0
                        bus_rdata <= (cnt != 4'd0) ? {1'b1, 2'd0, fifo[rp]} : 32'd0;
                    end
                    default: begin
                        bus_rdata <= 32'd0;
                    end
                endcase
            end
        end
    end

    // Khử cảnh báo linter đối với các bit dữ liệu ghi không dùng
    wire unused_ok = &{1'b0, bus_wdata[31:6], bus_wdata[4:3]};

endmodule
