// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     alarm_controller.v — Bộ Điều Khiển 4 Kênh Báo Thức Độc Lập
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra, Bộ Định Thời & So Sánh Báo Thức
// VAI TRÒ:        Bộ So Sánh Thời Gian Thực 4 Kênh & Mặt Nạ Thứ (Alarm Controller)
// MÔ TẢ:          Module quản lý 4 mốc báo thức độc lập, mỗi kênh hỗ trợ cấu hình:
//                 cho phép (en), mặt nạ 7 thứ trong tuần (mask), và thời điểm phút trong ngày (minute).
//                 Tích hợp mạch nhân hằng số 60.000 không dùng DSP (Multiplier-free Shifter-Adder),
//                 và cơ chế khử báo động giả khi RTC đang nạp giờ mới (Loading Protection).
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Cấu trúc 4 kênh báo thức độc lập:
//    - Mỗi kênh chiếm 1 thanh ghi 32-bit trong không gian MMIO:
//        + ALARM0: 0x30
//        + ALARM1: 0x34
//        + ALARM2: 0x38
//        + ALARM3: 0x3C
//    - Định dạng từng thanh ghi ALARM_i:
//        + Bit [31]    : Cho phép báo thức hoạt động (en).
//        + Bit [30:24] : Mặt nạ thứ trong tuần (mask 7-bit, bit k = 1 nghĩa là báo vào thứ k, 0=CN .. 6=T7).
//        + Bit [23]    : Cờ báo đã chạm mốc (hit sticky flag, ghi 1 để xóa).
//        + Bit [22:11] : Dự phòng (0).
//        + Bit [10:0]  : Phút trong ngày (minute, 0 .. 1439, tương đương 00:00 đến 23:59).
//
// 2. Tối ưu hóa phần cứng không dùng bộ nhân (Multiplier-Free Constant Shifter-Adder):
//    - Để so sánh trực tiếp với bộ đếm mili-giây của RTC, phần cứng cần đổi:
//        target_ms = minute * 60.000 (ms).
//    - Hằng số 60.000 = 0xEA60 có biểu diễn nhị phân:
//        60.000 = 2^15 + 2^14 + 2^13 + 2^11 + 2^9 + 2^6 + 2^5 (tổng của 7 lũy thừa 2).
//    - Khối thực hiện phép nhân này ngay khi CPU ghi giá trị `minute` bằng mạng cộng dịch bit:
//        w_target = (m << 15) + (m << 14) + (m << 13) + (m << 11) + (m << 9) + (m << 6) + (m << 5).
//      Kỹ thuật này giúp loại bỏ hoàn toàn bộ nhân DSP phần cứng cồng kềnh, tiết kiệm tài nguyên FPGA.
//
// 3. Cơ chế chống báo động giả khi RTC nạp giờ (Glitch-Free Loading Protection):
//    - Khi CPU chỉnh giờ RTC, trong chu kỳ chuyển giao (loading = 1), giá trị `ms` và `dow`
//      chưa ổn định. Tín hiệu `inc = tick_ms && !loading` khóa bộ so sánh trong chu kỳ này.
//    - Phép so sánh được thực hiện ở chu kỳ `chk` (ngay sau cạnh tăng giá trị mới của RTC):
//        new_hit[g] = chk && en[g] && (ms == target[g]) && mask[g][dow];
//      Đảm bảo báo thức chỉ phát đúng ở mili-giây đầu tiên của phút đã cài đặt.
// ============================================================================

`timescale 1ns/1ps

module alarm (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,        // Xung nhịp hệ thống 50 MHz
    input  wire        rst,        // Reset đồng bộ mức cao (Active-high Reset)
    input  wire        inc,        // Xung nhịp đồng bộ từ RTC: tick_ms && !loading (báo RTC vừa tăng)
    input  wire [26:0] ms,         // Mili-giây hiện tại trong ngày từ RTC (0 .. 86.399.999)
    input  wire [2:0]  dow,        // Thứ trong tuần từ RTC (0=Chủ Nhật .. 6=Thứ Bảy)
    
    // Giao diện Bus MMIO
    input  wire [7:0]  bus_addr,   // Địa chỉ thanh ghi ngoại vi (0x30 .. 0x3C)
    input  wire [31:0] bus_wdata,  // Dữ liệu ghi từ CPU
    input  wire        bus_we,     // Tín hiệu ghi MMIO (Write Enable)
    input  wire        bus_re,     // Tín hiệu đọc MMIO (Read Enable)
    output reg  [31:0] bus_rdata,  // Dữ liệu đọc trả về cho CPU
    
    // Tín hiệu ngắt sự kiện
    output reg         ev          // Xung sự kiện ngắt ALARM (nối tới IRQ Controller bit 3)
);

    // ------------------------------------------------------------------------
    // CẤU TRÚC THANH GHI 4 KÊNH BÁO THỨC (4 ALARM CHANNELS STORAGE)
    // ------------------------------------------------------------------------
    reg        en     [0:3];       // Trạng thái bật/tắt của từng kênh
    reg [6:0]  mask   [0:3];       // Mặt nạ 7 ngày trong tuần của từng kênh (bit k tương ứng thứ k)
    reg        hit    [0:3];       // Cờ chốt báo thức đã được kích hoạt (Sticky hit flag)
    reg [10:0] minute [0:3];       // Phút trong ngày (0 .. 1439)
    reg [26:0] target [0:3];       // Mốc mili-giây mục tiêu đã tính sẵn (target = minute * 60.000)
    reg        chk;                // Xung trễ 1 chu kỳ clock sau inc để chờ ms/dow ổn định

    // Giải mã địa chỉ bus MMIO: 0x30 đến 0x3C
    wire       is_al = (bus_addr[7:4] == 4'h3);
    wire [1:0] sel   = bus_addr[3:2];              // Chọn kênh báo thức (0..3)

    // ------------------------------------------------------------------------
    // MẠCH NHÂN HẰNG SỐ 60.000 KHÔNG DÙNG BỘ NHÂN (CONSTANT MULTIPLIER)
    // ------------------------------------------------------------------------
    // 60.000 = 2^15 + 2^14 + 2^13 + 2^11 + 2^9 + 2^6 + 2^5
    wire [26:0] m27      = {16'd0, bus_wdata[10:0]};
    wire [26:0] w_target = (m27 << 15) + (m27 << 14) + (m27 << 13) + 
                           (m27 << 11) + (m27 << 9)  + (m27 << 6)  + (m27 << 5);

    // ------------------------------------------------------------------------
    // BỘ SO SÁNH THỜI GIAN THỰC 4 KÊNH SONG SONG (PARALLEL REAL-TIME COMPARATOR)
    // ------------------------------------------------------------------------
    // Kênh g được kích hoạt khi:
    // 1. Đúng thời điểm sau nhịp tăng RTC (chk = 1).
    // 2. Kênh đang được bật (en[g] = 1).
    // 3. Thời điểm mili-giây trùng khớp chính xác (ms == target[g]).
    // 4. Thứ hiện tại được cho phép trong mặt nạ (mask[g][dow] = 1).
    wire [3:0] new_hit;
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_cmp
            assign new_hit[g] = chk && en[g] && (ms == target[g]) && mask[g][dow];
        end
    endgenerate

    integer i;

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ (SEQUENTIAL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 4; i = i + 1) begin
                en[i]     <= 1'b0;
                mask[i]   <= 7'd0;
                hit[i]    <= 1'b0;
                minute[i] <= 11'd0;
                target[i] <= 27'd0;
            end
            chk       <= 1'b0;
            ev        <= 1'b0;
            bus_rdata <= 32'd0;
        end else begin
            chk <= inc;
            ev  <= |new_hit;                       // Phát xung ngắt khi có bất kỳ kênh nào trúng mốc

            for (i = 0; i < 4; i = i + 1) begin
                // Giao tiếp ghi từ CPU vào kênh tương ứng
                if (bus_we && is_al && (sel == i[1:0])) begin
                    en[i]     <= bus_wdata[31];
                    mask[i]   <= bus_wdata[30:24];
                    minute[i] <= bus_wdata[10:0];
                    target[i] <= w_target;
                end

                // Quản lý cờ hit:
                // Sự kiện trúng mốc có độ ưu tiên cao nhất (set hit = 1)
                if (new_hit[i]) begin
                    hit[i] <= 1'b1;
                end else if (bus_we && is_al && (sel == i[1:0]) && bus_wdata[23]) begin
                    hit[i] <= 1'b0;                // Ghi bit [23] = 1 để xóa cờ hit
                end
            end

            // Giao tiếp đọc bus MMIO
            if (bus_re) begin
                if (is_al) begin
                    // Trả về định dạng: {en[31], mask[30:24], hit[23], 12'd0, minute[10:0]}
                    bus_rdata <= {en[sel], mask[sel], hit[sel], 12'd0, minute[sel]};
                end else begin
                    bus_rdata <= 32'd0;
                end
            end
        end
    end

    // Khử cảnh báo linter đối với các bit dữ liệu ghi không dùng
    wire unused_ok = &{1'b0, bus_wdata[22:11], bus_addr[1:0]};

endmodule
