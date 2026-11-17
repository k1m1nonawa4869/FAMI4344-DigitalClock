// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     soc_top.v — Thiết Kế Tích Hợp Hệ Thống Trên Chip (SoC Top-Level)
// VAI TRÒ:        Tích hợp toàn diện lõi CPU MIPS32 (G1 Đơn chu kỳ / G2 Pipeline)
//                 với Bus MMIO trung tâm, 4 khối Timer rời, khối hiển thị LED,
//                 bàn phím nút bấm, truyền thông UART và điều khiển ngắt
// ============================================================================
// 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
//    - Kiến trúc Hệ Thống Trên Chip (System-on-Chip - SoC Integration):
//      Theo giáo trình Patterson & Hennessy (Computer Organization and Design, §B.8),
//      SoC tích hợp CPU, bộ nhớ lệnh/dữ liệu và toàn bộ ngoại vi vào cùng một chip.
//    - Cơ chế Vào/Ra Ánh Xạ Bộ Nhớ (Memory-Mapped I/O - MMIO):
//      Không gian I/O được quy chuẩn vào dải địa chỉ cao 0xFFFF0000..0xFFFFFFFF.
//      CPU sử dụng cùng các lệnh tải/lưu dữ liệu tiêu chuẩn (lw/sw) để truy xuất
//      thanh ghi phần cứng mà không cần các lệnh vào/ra chuyên biệt (như in/out của x86).
//    - Kiến trúc Bus Phân Tán Gom Phép OR (Distributed OR-Reduction Bus Topology):
//      Trong thiết kế vi mạch ASIC/FPGA hiện đại, kiến trúc Bus 3 trạng thái (Tri-state 'Z')
//      nội bộ bị cấm do gây bất định thời gian, tiêu tán năng lượng cao và tải dung lớn.
//      SoC sử dụng cấu trúc Bus ghép kênh phân tán: Mọi ngoại vi nhận chung bus_addr,
//      bus_wdata, bus_we, bus_re. Khi không được chọn, ngoại vi bắt buộc trả về 32'd0.
//      Đường dữ liệu đọc về CPU đơn giản là phép OR bit của tất cả các khối:
//        bus_rdata = rd_soc | rd_irq | rd_rtc | rd_sw | rd_tmr | rd_al | rd_btn | rd_disp | rd_uart | rd_bcd;
//    - Triệt tiêu trễ phần mềm với Hardware Capture (Zero-Latency Event Latching):
//      Các tín hiệu nút bấm (A, B) được kết nối trực tiếp từ buttons sang stopwatch_core,
//      cho phép ghi lại khoảnh khắc bấm giờ tức thời với độ trễ 0 ns mà không phụ
//      thuộc vào tần số quét hoặc độ trễ phản hồi ngắt của CPU.
//
// 2. PHÂN PHỐI XUNG NHỊP, RESET & HỆ THỐNG NGOẠI VI:
//    - Khử hiện tượng siêu ổn định cho Reset (2-FF Synchronizer):
//      Tín hiệu reset_in bên ngoài được đồng bộ hóa qua 2 tầng flip-flop rst_sync
//      để sinh ra tín hiệu reset rst đồng bộ, an toàn cho toàn hệ thống.
//    - Miền xung nhịp & Bộ điều chế nhịp (Clock Enable Pacing):
//      + Toàn bộ hệ thống chạy trên xung nhịp duy nhất clk (50 MHz).
//      + timebase sinh nhịp chuẩn 1 ms (1 kHz) có hiệu chuẩn bù sai số thạch anh (cal).
//      + soc_regs điều chế xung cpu_ce để điều chỉnh tốc độ CPU (phục vụ thí nghiệm DSE).
//    - 4 Khối Đo Thời Gian Độc Lập (Modular Timer Cores):
//      + rtc_core: Đồng hồ thời gian thực (ms trong ngày, ngày, thứ, nạp giờ 2 pha an toàn).
//      + stopwatch_core: Bấm giờ độ phân giải 1 ms, bộ nhớ đệm vòng tròn 8 Lap cứng.
//      + countdown_core: Đếm ngược thời gian, hỗ trợ đếm bù âm quá giờ và báo động.
//      + alarm_controller: 4 kênh báo thức độc lập theo ngày trong tuần và giờ:phút.
//    - Hệ Thống Ngoại Vi Tương Tác:
//      + buttons: 4 nút bấm khử rung FSM 10 ms và hàng đợi FIFO tem thời gian.
//      + display_ctrl: Quét TDM 8 LED 7 thanh đa hợp, khoảng làm tối chống bóng ma 100 ns.
//      + beeper: Bộ điều chế PWM 2 kHz và phát chuỗi giai điệu cảnh báo.
//      + uart: Giao tiếp truyền thông nối tiếp 115200 8N1 có FIFO đệm 64 byte.
//      + irq_ctrl: Tổng hợp 8 nguồn ngắt ngoại vi, quản lý mặt nạ và cờ W1C.
//
// 3. THAM SỐ CẤU HÌNH & TỐI ƯU HÓA MÔ PHỎNG:
//    - G_CORE: 1 = Lõi đơn chu kỳ G1 (cpu_g1); 2 = Lõi đường ống 5 tầng G2 (cpu_pipe).
//    - G_N: Số chu kỳ clock / 1 ms (50000 ở phần cứng 50 MHz; 50 khi mô phỏng RTL).
//    - G_SLOT: Chu kỳ chuyển khe LED 7 đoạn (50000 ở phần cứng; 40 khi mô phỏng).
//    - G_BLANK: Chu kỳ làm tối LED chống bóng ma (100 ở phần cứng; 4 khi mô phỏng).
//    - G_BIT: Chu kỳ mỗi bit UART (434 ở 50 MHz 115200 baud; 8 khi mô phỏng).
//    - G_BCD_RTC: 1 = Tích hợp bộ giải mã BCD phần cứng; 0 = Không dùng (tiết kiệm tài nguyên).
//    - VGA REMOVAL: Các chân tín hiệu VGA đã được loại bỏ hoàn toàn để tăng tốc mô phỏng.
// ============================================================================

`timescale 1ns/1ps

module soc_top #(
    parameter IMEM_FILE        = "",          // Đường dẫn tệp hex bộ nhớ lệnh IMEM
    parameter DMEM_FILE        = "",          // Đường dẫn tệp hex bộ nhớ dữ liệu DMEM
    parameter G_IMEM_AW        = 11,          // Độ rộng địa chỉ IMEM (11 bit = 2048 từ lệnh)
    parameter G_BCD_COMB       = 0,           // 0: BCD tuần tự 27 chu kỳ; 1: BCD tổ hợp
    parameter G_N              = 50000,       // Chu kỳ clock / 1 ms (mô phỏng: 50)
    parameter G_SLOT           = 50000,       // Chu kỳ clock / 1 khe quét LED (mô phỏng: 40)
    parameter G_BLANK          = 100,         // Chu kỳ làm tối chống bóng ma LED (mô phỏng: 4)
    parameter G_BTN_ACTIVE_LOW = 0,           // 0: Nút bấm tích cực cao; 1: Nút bấm tích cực thấp
    parameter G_BIT            = 434,         // Chu kỳ clock / 1 bit UART 115200 (mô phỏng: 8)
    parameter G_BCD_RTC        = 0,           // 1: Bật khối rtc_bcd phần cứng; 0: Tắt
    parameter TRACE_FILE       = ""           // Tệp ghi vết thực thi mô phỏng
) (
    input  wire        clk,                   // Xung nhịp hệ thống chính 50 MHz
    input  wire        rst_in,                // Tín hiệu reset ngoài (được đồng bộ hóa 2-FF)
    input  wire [3:0]  btn,                   // 4 nút bấm điều khiển (MODE, A, B, C)
    output wire [7:0]  an,                    // Tín hiệu điều khiển Anode 8 LED 7 thanh (tích cực thấp)
    output wire [6:0]  seg,                   // Tín hiệu Cathode thanh a..g (tích cực thấp)
    output wire        dp,                    // Tín hiệu dấu chấm thập phân LED (tích cực thấp)
    output wire        beep,                  // Ngõ ra điều khiển còi xung PWM 2 kHz
    input  wire        uart_rx,               // Ngõ vào nối tiếp UART RX
    output wire        uart_tx                // Ngõ ra nối tiếp UART TX
);

    // ------------------------------------------------------------------------
    // 1. MẠCH ĐỒNG BỘ HÓA RESET (2-FLIP-FLOP RESET SYNCHRONIZER)
    // ------------------------------------------------------------------------
    reg [1:0] rst_sync;
    always @(posedge clk) begin
        rst_sync <= {rst_sync[0], rst_in};
    end
    wire rst = rst_sync[1];

    // ------------------------------------------------------------------------
    // 2. CẤU TRÚC BUS MMIO TẬP TRUNG (CENTRALIZED MMIO BUS INTERCONNECT)
    // ------------------------------------------------------------------------
    wire [7:0]  bus_addr;                     // Byte thấp của địa chỉ MMIO (0x00 .. 0xFC)
    wire [31:0] bus_wdata;                    // Dữ liệu ghi từ CPU ra Bus
    wire        bus_we;                       // Tín hiệu cho phép ghi Bus (Write Enable)
    wire        bus_re;                       // Tín hiệu cho phép đọc Bus (Read Enable)

    // Các đường dữ liệu đọc riêng biệt của từng khối ngoại vi (mỗi khối trả 0 khi không trúng địa chỉ)
    wire [31:0] rd_soc;                       // Đọc từ soc_regs
    wire [31:0] rd_irq;                       // Đọc từ irq_ctrl
    wire [31:0] rd_rtc;                       // Đọc từ rtc_core
    wire [31:0] rd_sw;                        // Đọc từ stopwatch_core
    wire [31:0] rd_tmr;                       // Đọc từ countdown_core
    wire [31:0] rd_al;                        // Đọc từ alarm_controller
    wire [31:0] rd_btn;                       // Đọc từ buttons
    wire [31:0] rd_disp;                      // Đọc từ display_ctrl
    wire [31:0] rd_uart;                      // Đọc từ uart
    wire [31:0] rd_bcd;                       // Đọc từ rtc_bcd (tùy chọn)

    // Bus dữ liệu đọc trả về CPU qua phép OR bit phân tán
    wire [31:0] bus_rdata = rd_soc  | rd_irq  | rd_rtc  | rd_sw   | rd_tmr |
                            rd_al   | rd_btn  | rd_disp | rd_uart | rd_bcd;

    // ------------------------------------------------------------------------
    // 3. CÁC TÍN HIỆU ĐIỀU KHIỂN & SỰ KIỆN LIÊN KHỐI
    // ------------------------------------------------------------------------
    wire        cpu_ce;                       // Xung cho phép CPU bước từ soc_regs
    wire        irq;                          // Tín hiệu yêu cầu ngắt gửi CPU
    wire [7:0]  irq_ip;                       // Vector cờ ngắt đang chờ (Cause.IP)
    wire        div_dz;                       // Cờ chia cho 0 từ CPU chuyển sang soc_regs
    wire        retire;                       // Lệnh hoàn thành (phục vụ mô phỏng trace)
    wire [31:0] pc;                           // Giá trị con trỏ lệnh PC hiện tại
    wire [31:0] cycle_count;                  // Bộ đếm chu kỳ hệ thống cấp cho irq_ctrl
    wire signed [31:0] cal;                   // Giá trị hiệu chỉnh ppm cấp cho timebase & timers
    wire        tick_ms;                      // Nhịp chuẩn 1 ms từ timebase
    wire        tick_1s;                      // Xung nhịp 1 giây từ rtc_core
    wire        loading;                      // Cờ báo rtc_core đang trong chu kỳ nạp giờ an toàn
    wire [26:0] ms;                           // Mili-giây hiện tại trong ngày (0..86399999)
    wire [15:0] day;                          // Số ngày từ mốc quy chuẩn
    wire [2:0]  dow;                          // Thứ trong tuần (0: CN, 1: T2, ..., 6: T7)
    wire        tmr_zero;                     // Sự kiện đếm lùi về 0 từ countdown_core
    wire        tmr_beep;                     // Tín hiệu kích hoạt còi phần cứng khi hết giờ đếm lùi
    wire        alarm_ev;                     // Sự kiện báo thức trùng khớp từ alarm_controller
    wire        sw_capture;                   // Sự kiện chụp Lap từ stopwatch_core
    wire        btn_ev;                       // Sự kiện nhấn nút từ buttons
    wire        sounding;                     // Cờ báo còi đang phát âm thanh
    wire        uart_rx_ev;                   // Sự kiện nhận ký tự UART mới
    wire        uart_tx_ev;                   // Sự kiện đệm phát UART trống
    wire [3:0]  press;                        // Xung cạnh nhấn nút trực tiếp (press[1]=A, press[2]=B)

    // ------------------------------------------------------------------------
    // 4. KHỐI XỬ LÝ TRUNG TÂM (CPU CORE INSTANCE: G1 HOẶC G2)
    // ------------------------------------------------------------------------
`ifdef G2
    localparam G_CORE = 2;
    cpu_pipe #(
        .IMEM_FILE  (IMEM_FILE),
        .DMEM_FILE  (DMEM_FILE),
        .G_IMEM_AW  (G_IMEM_AW),
        .G_BCD_COMB (G_BCD_COMB),
        .TRACE_FILE (TRACE_FILE)
    ) u_cpu (
        .clk        (clk),
        .rst        (rst),
        .cpu_ce     (cpu_ce),
        .bus_addr   (bus_addr),
        .bus_wdata  (bus_wdata),
        .bus_we     (bus_we),
        .bus_re     (bus_re),
        .bus_rdata  (bus_rdata),
        .irq        (irq),
        .irq_ip     (irq_ip),
        .div_dz     (div_dz),
        .pc_out     (pc),
        .retire     (retire)
    );
`else
    localparam G_CORE = 1;
    cpu_g1 #(
        .IMEM_FILE  (IMEM_FILE),
        .DMEM_FILE  (DMEM_FILE),
        .G_IMEM_AW  (G_IMEM_AW),
        .G_BCD_COMB (G_BCD_COMB),
        .TRACE_FILE (TRACE_FILE)
    ) u_cpu (
        .clk        (clk),
        .rst        (rst),
        .cpu_ce     (cpu_ce),
        .bus_addr   (bus_addr),
        .bus_wdata  (bus_wdata),
        .bus_we     (bus_we),
        .bus_re     (bus_re),
        .bus_rdata  (bus_rdata),
        .irq        (irq),
        .irq_ip     (irq_ip),
        .div_dz     (div_dz),
        .pc_out     (pc),
        .retire     (retire)
    );
`endif

    // ------------------------------------------------------------------------
    // 5. THANH GHI HỆ THỐNG VÀ ĐIỀU KHIỂN NHỊP CPU (SOC_REGS)
    // ------------------------------------------------------------------------
    soc_regs #(
        .G_CORE      (G_CORE)
    ) u_regs (
        .clk         (clk),
        .rst         (rst),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .bus_re      (bus_re),
        .bus_rdata   (rd_soc),
        .div_dz      (div_dz),
        .cycle_count (cycle_count),
        .cal         (cal),
        .cpu_ce      (cpu_ce)
    );

    // ------------------------------------------------------------------------
    // 6. BỘ ĐIỀU KHIỂN NGẮT 8 NGUỒN (INTERRUPT CONTROLLER)
    // ------------------------------------------------------------------------
    // Ánh xạ nguồn ngắt (mmio-map §5):
    //   bit 0: TICK_1MS,     bit 1: TICK_1S,       bit 2: TMR_ZERO, bit 3: ALARM,
    //   bit 4: SW_CAPTURE,   bit 5: BTN,           bit 6: UART_RX,  bit 7: UART_TX_EMPTY
    irq_ctrl u_irq (
        .clk         (clk),
        .rst         (rst),
        .ev          ({uart_tx_ev, uart_rx_ev, btn_ev, sw_capture, alarm_ev, tmr_zero, tick_1s, tick_ms}),
        .cycle_count (cycle_count),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .bus_re      (bus_re),
        .bus_rdata   (rd_irq),
        .irq         (irq),
        .ip          (irq_ip)
    );

    // ------------------------------------------------------------------------
    // 7. BỘ TẠO NHỊP CƠ SỞ CHUẨN 1 MS (FRACTIONAL TIMEBASE)
    // ------------------------------------------------------------------------
    timebase #(
        .G_N         (G_N)
    ) u_tb (
        .clk         (clk),
        .rst         (rst),
        .clr         (1'b0),
        .en          (1'b1),
        .cal         (cal),
        .tick        (tick_ms)
    );

    // ------------------------------------------------------------------------
    // 8. ĐỒNG HỒ THỜI GIAN THỰC (RTC CORE)
    // ------------------------------------------------------------------------
    rtc u_rtc (
        .clk         (clk),
        .rst         (rst),
        .tick_ms     (tick_ms),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .bus_re      (bus_re),
        .bus_rdata   (rd_rtc),
        .ms          (ms),
        .day         (day),
        .dow         (dow),
        .tick_1s     (tick_1s),
        .loading     (loading)
    );

    // ------------------------------------------------------------------------
    // 9. BỘ BẤM GIỜ THỂ THAO (STOPWATCH CORE)
    // ------------------------------------------------------------------------
    // Nhận trực tiếp xung nhấn nút press_a (Start/Stop) và press_b (Lap)
    // từ khối buttons để chụp thời gian tức thời với độ trễ 0 ns.
    stopwatch #(
        .G_N         (G_N)
    ) u_sw (
        .clk         (clk),
        .rst         (rst),
        .cal         (cal),
        .press_a     (press[1]),
        .press_b     (press[2]),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .bus_re      (bus_re),
        .bus_rdata   (rd_sw),
        .capture     (sw_capture)
    );

    // ------------------------------------------------------------------------
    // 10. BỘ HẸN GIỜ ĐẾM LÙI (COUNTDOWN TIMER CORE)
    // ------------------------------------------------------------------------
    cdtimer #(
        .G_N         (G_N)
    ) u_tmr (
        .clk         (clk),
        .rst         (rst),
        .cal         (cal),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .bus_re      (bus_re),
        .bus_rdata   (rd_tmr),
        .zero_ev     (tmr_zero),
        .beep        (tmr_beep)
    );

    // ------------------------------------------------------------------------
    // 11. BỘ ĐIỀU KHIỂN BÁO THỨC 4 KÊNH (ALARM CONTROLLER)
    // ------------------------------------------------------------------------
    alarm u_al (
        .clk         (clk),
        .rst         (rst),
        .inc         (tick_ms && !loading),
        .ms          (ms),
        .dow         (dow),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .bus_re      (bus_re),
        .bus_rdata   (rd_al),
        .ev          (alarm_ev)
    );

    // ------------------------------------------------------------------------
    // 12. KHỐI NÚT BẤM KHỬ RUNG & HÀNG ĐỢI SỰ KIỆN (BUTTONS CONTROLLER)
    // ------------------------------------------------------------------------
    buttons #(
        .G_ACTIVE_LOW (G_BTN_ACTIVE_LOW)
    ) u_btn (
        .clk         (clk),
        .rst         (rst),
        .btn         (btn),
        .tick_ms     (tick_ms),
        .ms          (ms),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .bus_re      (bus_re),
        .bus_rdata   (rd_btn),
        .press       (press),
        .ev          (btn_ev)
    );

    // ------------------------------------------------------------------------
    // 13. KHỐI ĐIỀU CHẾ ÂM THANH CÒI BUZZER (PWM BEEPER)
    // ------------------------------------------------------------------------
    beeper u_beep (
        .clk         (clk),
        .rst         (rst),
        .tick_ms     (tick_ms),
        .hw_trig     (tmr_beep),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .beep        (beep),
        .sounding    (sounding)
    );

    // ------------------------------------------------------------------------
    // 14. KHỐI QUÉT HIỂN THỊ LED 7 ĐOẠN ĐA HỢP (DISPLAY CONTROLLER)
    // ------------------------------------------------------------------------
    // Chú ý: Các cổng VGA (vga_hs, vga_vs, vga_rgb) được bỏ ngỏ để tối ưu hóa
    // tốc độ mô phỏng và loại bỏ tài nguyên phần cứng không dùng tới.
    display_ctrl #(
        .G_SLOT      (G_SLOT),
        .G_BLANK     (G_BLANK)
    ) u_disp (
        .clk         (clk),
        .rst         (rst),
        .tick_ms     (tick_ms),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .bus_re      (bus_re),
        .bus_rdata   (rd_disp),
        .an          (an),
        .seg         (seg),
        .dp          (dp),
        .vga_hs      (),
        .vga_vs      (),
        .vga_rgb     ()
    );

    // ------------------------------------------------------------------------
    // 15. NGOẠI VI NỐI TIẾP UART 115200 8N1 (UART CONTROLLER)
    // ------------------------------------------------------------------------
    uart #(
        .G_BIT       (G_BIT)
    ) u_uart (
        .clk         (clk),
        .rst         (rst),
        .rx          (uart_rx),
        .tx          (uart_tx),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_we      (bus_we),
        .bus_re      (bus_re),
        .bus_rdata   (rd_uart),
        .rx_ev       (uart_rx_ev),
        .tx_ev       (uart_tx_ev)
    );

    // ------------------------------------------------------------------------
    // 16. BỘ BẬT/TẮT TÙY CHỌN BCD PHẦN CỨNG (OPTIONAL HARDWARE BCD UNIT)
    // ------------------------------------------------------------------------
    generate
        if (G_BCD_RTC) begin : g_bcd
            rtc_bcd u_bcd (
                .clk       (clk),
                .rst       (rst),
                .tick_ms   (tick_ms),
                .bus_addr  (bus_addr),
                .bus_wdata (bus_wdata),
                .bus_we    (bus_we),
                .bus_re    (bus_re),
                .bus_rdata (rd_bcd)
            );
        end else begin : g_nobcd
            assign rd_bcd = 32'd0;
        end
    endgenerate

    // Tín hiệu quan sát mô phỏng (tránh cảnh báo tín hiệu unused)
    wire unused_ok = &{1'b0, retire, pc, day, sounding, press[3], press[0]};

endmodule
