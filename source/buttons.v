// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     buttons.v — Khối Đồng Bộ Hóa 2-FF, Khử Rung & Hàng Đợi Nút Bấm
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra, Đồng Bộ Tín Hiệu & Khử Rung Ngoại Vi
// VAI TRÒ:        Giao Tiếp Nút Bấm Cơ Khí Bất Đồng Bộ & Lọc Tiếp Điểm (Debounce)
// MÔ TẢ:          Module quản lý 4 nút bấm cơ khí (MODE=0, A=1, B=2, C=3):
//                 - Đồng bộ hóa qua 2 tầng Flip-Flop chống hiện tượng bán ổn định (Metastability).
//                 - Máy trạng thái 4 pha khử rung tiếp điểm (Debouncing FSM) với bộ đếm 10 ms.
//                 - Kích hoạt cạnh đầu (Leading Edge Trigger) độ trễ 0-ns cho các bộ bấm giờ thể thao.
//                 - Hàng đợi FIFO 4 phần tử lưu trữ mã nút và dấu thời gian ms (Timestamp).
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Hiện tượng bán ổn định (Metastability) và Bộ đồng bộ hóa 2-FF:
//    - Tín hiệu từ nút bấm vật lý là tín hiệu bất đồng bộ (asynchronous), có thể thay đổi
//      mức điện áp vào đúng cửa sổ thời gian thiết lập (t_setup) hoặc thời gian giữ (t_hold)
//      của Flip-Flop trong miền xung nhịp hệ thống 50 MHz.
//    - Khi đó, đầu ra Flip-Flop có thể dao động ở mức điện áp trung gian không xác định
//      (giữa 0 và 1) trong một khoảng thời gian gọi là trạng thái bán ổn định.
//    - Công thức tính thời gian trung bình giữa hai lỗi (MTBF - Mean Time Between Failures):
//          MTBF = exp(t_r / tau) / (T_0 * f_clk * f_data)
//      Trong đó:
//        + t_r: Thời gian hồi phục (Resolution time) cho phép tín hiệu ổn định.
//        + tau, T_0: Các thông số vật lý của công nghệ chế tạo cổng logic.
//        + f_clk: Tần số xung nhịp hệ thống (50 MHz).
//        + f_data: Tần số thay đổi của dữ liệu đầu vào.
//    - Giải pháp 2 tầng Flip-Flop (s1, s2): Tầng FF thứ nhất hấp thụ khả năng bán ổn định.
//      Sau đúng 1 chu kỳ xung nhịp (20 ns), hầu như toàn bộ trạng thái bất định đều đã
//      hồi phục về mức 0 hoặc 1 ổn định trước khi được tầng FF thứ hai chốt lại, tăng MTBF
//      từ vài micro-giây lên hàng triệu năm vận hành an toàn.
//
// 2. Hiện tượng rung tiếp điểm cơ học (Contact Bounce) & FSM khử rung:
//    - Khi người dùng bấm hoặc nhả nút cơ khí, các lá đồng bên trong va chạm và nảy liên tục
//      tạo ra một chuỗi xung đóng/ngắt giả trong khoảng 1 đến 5 ms.
//    - Máy trạng thái 4 pha khử rung cho mỗi nút:
//        + S_IDLE   : Trạng thái chờ. Khi phát hiện nút được nhấn, kích hoạt NGAY LẬP TỨC
//                     xung `press` (1 chu kỳ) và chụp ngay mốc thời gian `ts = ms` (không chờ
//                     để đạt độ trễ 0-ns cho khối Stopwatch). Sau đó chuyển sang S_LOCK_P.
//        + S_LOCK_P : Khóa khử rung nhấn. Giữ nguyên trạng thái trong 10 ms (10 xung tick_ms),
//                     bỏ qua mọi biến thiên tiếp điểm. Hết 10 ms: Nếu vẫn đang giữ phím -> S_HELD;
//                     nếu đã nhả -> S_IDLE.
//        + S_HELD   : Trạng thái giữ phím. Chờ đến khi người dùng nhả phím -> chuyển S_LOCK_R.
//        + S_LOCK_R : Khóa khử rung nhả. Khóa 10 ms để triệt tiêu hiện tượng nảy khi nhả phím,
//                     sau đó quay về S_IDLE.
//
// 3. Hàng đợi sự kiện FIFO 4 phần tử & Dấu thời gian (Event FIFO & Timestamping):
//    - Mỗi lần nhấn hợp lệ được đóng gói thành một bản ghi sự kiện 29-bit: `{code[1:0], ts[26:0]}`
//      (gồm mã định danh nút và dấu thời gian ms lúc cạnh nhấn bắt đầu).
//    - Xử lý xung đột khi nhiều nút nhấn cùng chu kỳ: Mạch giải mã ưu tiên chọn nút có chỉ số nhỏ
//      nhất ghi trước vào FIFO, các nút còn lại được giữ trong thanh ghi chờ `pend` để ghi ở các chu kỳ kế tiếp.
//    - Cờ cảnh báo tràn `lost`: Bật lên 1 khi FIFO đầy mà người dùng vẫn nhấn thêm nút mới.
// ============================================================================

`timescale 1ns/1ps

module buttons #(
    parameter G_ACTIVE_LOW = 0          // 1 nếu mạch phần cứng nút bấm kéo xuống đất (Active-low: 0 = nhấn)
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,             // Xung nhịp hệ thống 50 MHz
    input  wire        rst,             // Reset đồng bộ mức cao (Active-high Reset)
    input  wire [3:0]  btn,             // Tín hiệu 4 nút bấm vật lý bất đồng bộ (MODE=0, A=1, B=2, C=3)
    input  wire        tick_ms,         // Xung nhịp chuẩn 1 ms từ bộ chia timebase
    input  wire [26:0] ms,              // Giá trị thời gian thực MS_OF_DAY từ RTC (dùng làm timestamp)
    
    // Giao diện Bus MMIO
    input  wire [7:0]  bus_addr,        // Địa chỉ thanh ghi ngoại vi
    input  wire [31:0] bus_wdata,       // Dữ liệu ghi từ CPU (không dùng cho khối chỉ đọc này)
    input  wire        bus_we,          // Tín hiệu ghi MMIO
    input  wire        bus_re,          // Tín hiệu đọc MMIO
    output reg  [31:0] bus_rdata,       // Dữ liệu đọc trả về cho CPU
    
    // Tín hiệu bắt sự kiện phần cứng trực tiếp
    output wire [3:0]  press,           // Xung 1 chu kỳ báo sườn nhấn cạnh đầu (nối tới Stopwatch)
    output wire        ev               // Xung báo có sự kiện mới trong FIFO (nối tới IRQ Controller bit 5)
);

    // ------------------------------------------------------------------------
    // ĐỊA CHỈ THANH GHI VÀ TRẠNG THÁI FSM
    // ------------------------------------------------------------------------
    localparam A_EVT = 8'h40;           // 0x40: Đọc sự kiện phím từ FIFO (kèm tự động pop)
    
    // Các trạng thái của máy trạng thái khử rung
    localparam S_IDLE   = 2'd0,         // Chờ phím bấm
               S_LOCK_P = 2'd1,         // Khóa chống nảy tiếp điểm lúc nhấn (10 ms)
               S_HELD   = 2'd2,         // Đang giữ phím
               S_LOCK_R = 2'd3;         // Khóa chống nảy tiếp điểm lúc nhả (10 ms)

    // ------------------------------------------------------------------------
    // THANH GHI VÀ TÍN HIỆU NỘI BỘ (INTERNAL REGISTERS & SIGNALS)
    // ------------------------------------------------------------------------
    // Bộ đồng bộ hóa 2 tầng Flip-Flop chống hiện tượng bán ổn định
    reg [3:0]  s1, s2;
    
    // Máy trạng thái khử rung và bộ đếm 10 ms cho từng nút
    reg [1:0]  st  [0:3];
    reg [3:0]  cnt [0:3];
    
    // Thanh ghi lưu vết chờ ghi và dấu thời gian
    reg [3:0]  pend;                    // Cờ báo nút đã nhấn đang chờ nạp vào FIFO
    reg [26:0] ts  [0:3];               // Lưu mốc thời gian ms của từng nút tại cạnh nhấn đầu tiên
    
    // Hàng đợi tròn FIFO 4 sự kiện
    reg [28:0] fifo [0:3];              // Mỗi phần tử: {code[1:0], ts[26:0]}
    reg [1:0]  rp, wp;                  // Con trỏ đọc và ghi FIFO
    reg [2:0]  n;                       // Số lượng sự kiện hiện có trong FIFO (0..4)
    reg        lost;                    // Cờ cảnh báo mất sự kiện do FIFO bị đầy

    // Xử lý đảo cực theo tham số phần cứng G_ACTIVE_LOW
    localparam [3:0] IDLE_LVL = G_ACTIVE_LOW ? 4'hF : 4'h0;
    wire [3:0] lvl = G_ACTIVE_LOW ? ~s2 : s2;              // Chuẩn hóa: 1 = Phím đang được nhấn

    // ------------------------------------------------------------------------
    // LOGIC KÍCH HOẠT CẠNH ĐẦU ĐỘ TRỄ 0-NS (LEADING-EDGE TRIGGER)
    // ------------------------------------------------------------------------
    // Xung press bật đúng 1 chu kỳ khi nút đang ở IDLE và bắt đầu phát hiện mức tích cực
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_press
            assign press[g] = (st[g] == S_IDLE) && lvl[g];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // MẠCH GIẢI MÃ ƯU TIÊN GHI FIFO (PRIORITY ARBITER)
    // ------------------------------------------------------------------------
    // Nếu nhiều nút nhấn đồng thời, ưu tiên ghi nút có chỉ số nhỏ hơn trước
    reg        has;
    reg [1:0]  code;
    always @* begin
        has  = |pend;
        code = pend[0] ? 2'd0 : 
               pend[1] ? 2'd1 : 
               pend[2] ? 2'd2 : 2'd3;
    end

    // Điều kiện rút sự kiện: CPU đọc địa chỉ A_EVT khi FIFO có ít nhất 1 phần tử
    wire pop    = bus_re && (bus_addr == A_EVT) && (n != 3'd0);
    // Điều kiện nhận sự kiện vào FIFO: Có nút chờ VÀ (FIFO chưa đầy HOẶC đầy nhưng đang được pop)
    wire accept = has && ((n != 3'd4) || pop);
    // Xung ngắt báo cho CPU khi có sự kiện được nạp thành công vào FIFO
    assign ev   = accept;

    integer i;

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ (SEQUENTIAL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            s1   <= IDLE_LVL;
            s2   <= IDLE_LVL;
            pend <= 4'd0;
            for (i = 0; i < 4; i = i + 1) begin
                st[i]  <= S_IDLE;
                cnt[i] <= 4'd0;
                ts[i]  <= 27'd0;
            end
            rp        <= 2'd0;
            wp        <= 2'd0;
            n         <= 3'd0;
            lost      <= 1'b0;
            bus_rdata <= 32'd0;
        end else begin
            // 1. Tầng đồng bộ 2 Flip-Flop
            s1 <= btn;
            s2 <= s1;

            // 2. Máy trạng thái khử rung cho từng nút
            for (i = 0; i < 4; i = i + 1) begin
                case (st[i])
                    S_IDLE: begin
                        if (lvl[i]) begin
                            st[i]  <= S_LOCK_P; // Chuyển sang khóa khử rung nhấn
                            cnt[i] <= 4'd0;
                            ts[i]  <= ms;       // Chụp ngay mốc thời gian hiện tại
                        end
                    end
                    S_LOCK_P: begin
                        if (tick_ms) begin
                            if (cnt[i] == 4'd9) begin
                                // Sau 10 ms: Nếu vẫn còn nhấn thì vào HELD, nếu đã nhả thì về IDLE
                                st[i] <= lvl[i] ? S_HELD : S_IDLE;
                            end
                            cnt[i] <= cnt[i] + 4'd1;
                        end
                    end
                    S_HELD: begin
                        if (!lvl[i]) begin
                            st[i]  <= S_LOCK_R; // Phát hiện nhả: Vào khóa khử rung nhả
                            cnt[i] <= 4'd0;
                        end
                    end
                    default: begin // S_LOCK_R
                        if (tick_ms) begin
                            if (cnt[i] == 4'd9) begin
                                st[i] <= S_IDLE; // Sau 10 ms nhả ổn định: Quay về IDLE
                            end
                            cnt[i] <= cnt[i] + 4'd1;
                        end
                    end
                endcase
            end

            // 3. Quản lý hàng đợi FIFO 4 sự kiện
            if (accept) begin
                fifo[wp] <= {code, ts[code]};   // Lưu mã nút và mốc thời gian tương ứng
                wp       <= wp + 2'd1;
            end

            // Cập nhật các yêu cầu chờ ghi: xóa yêu cầu đã được chấp nhận và tích lũy các nút mới bấm
            pend <= (pend & ~(has ? (4'd1 << code) : 4'd0)) | press;

            if (pop) begin
                rp <= rp + 2'd1;
            end

            // Cập nhật số lượng phần tử trong FIFO
            n <= n + {2'd0, accept} - {2'd0, pop};

            // Quản lý cờ cảnh báo tràn lost
            if (has && !accept) begin
                lost <= 1'b1;                   // FIFO đầy: Bật cờ cảnh báo mất sự kiện
            end else if (bus_re && (bus_addr == A_EVT)) begin
                lost <= 1'b0;                   // Tự động xóa cờ lost sau khi CPU đọc xong
            end

            // 4. Giao diện đọc bus MMIO
            if (bus_re) begin
                if (bus_addr == A_EVT) begin
                    // Định dạng thanh ghi sự kiện A_EVT:
                    // Bit [31]   : 1 = Có dữ liệu sự kiện hợp lệ (Valid)
                    // Bit [30:29]: Mã nút (0=MODE, 1=A, 2=B, 3=C)
                    // Bit [28]   : Cờ lost (báo có sự kiện bị tràn mất)
                    // Bit [27]   : 0
                    // Bit [26:0] : Mốc thời gian ms lúc nhấn nút
                    bus_rdata <= (n != 3'd0) ? {1'b1, fifo[rp][28:27], lost, 1'b0, fifo[rp][26:0]}
                                             : {3'd0, lost, 28'd0};
                end else begin
                    bus_rdata <= 32'd0;
                end
            end
        end
    end

    // Khử cảnh báo linter đối với các tín hiệu ghi không sử dụng
    wire unused_ok = &{1'b0, bus_wdata, bus_we};

endmodule
