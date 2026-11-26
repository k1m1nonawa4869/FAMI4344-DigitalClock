// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     rtc_core.v — Khối Đếm Thời Gian Thực Cơ Sở (RTC Core)
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra & Bộ Định Thời (Timers & Clock Generators)
// VAI TRÒ:        Bộ Đếm Thời Gian Thực Phần Cứng & Chốt Bóng Nguyên Tử (RTC & Shadow Latching)
// MÔ TẢ:          Module đếm thời gian thực: mili-giây trong ngày (0 .. 86.399.999),
//                 số ngày (16-bit kể từ mốc 01/01/2000), và thứ trong tuần (0=CN .. 6=T7).
//                 Hỗ trợ cơ chế nạp giờ an toàn 2 pha (2-phase Arming) và cơ chế
//                 chốt bóng phần cứng (Atomic Shadow Latching) triệt tiêu lỗi đọc
//                 lệch sườn (Race Condition / data tearing) khi đồng hồ chuyển ngày.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Biểu diễn thời gian và chu kỳ đếm:
//    - Một ngày chuẩn có chính xác: 24h * 60m * 60s * 1000ms = 86.400.000 ms.
//    - Cần 27-bit để biểu diễn bộ đếm mili-giây (vì 2^26 = 67.108.864 < 86.400.000 < 2^27 = 134.217.728).
//    - Tại thời điểm 86.399.999 ms, khi nhận xung tick_ms tiếp theo:
//        + ms tự động quay vòng về 0.
//        + day tăng 1 (bộ đếm 16-bit quay vòng tại 65.535).
//        + dow (thứ trong tuần) tăng 1 (quay vòng từ 6 = Thứ Bảy về 0 = Chủ Nhật).
//
// 2. Cơ chế nạp giờ an toàn 2 pha (2-phase Arming Mechanism):
//    - Vấn đề: Nếu CPU ghi trực tiếp vào các thanh ghi đếm đang chạy ở giữa một mili-giây,
//      bộ đếm có thể rơi vào trạng thái bất định (metastable/glitch) hoặc xé số thời gian.
//    - Giải pháp: Phần mềm ghi thời gian mong muốn vào 2 thanh ghi đệm `SET_MS` và `SET_DAY`.
//      Sau đó phần mềm kích hoạt cờ ARM (bit 0 thanh ghi `RTC_CTRL`).
//      Phần cứng chỉ nạp dữ liệu từ các thanh ghi đệm vào bộ đếm chính xác tại sườn
//      xung `tick_ms` tiếp theo. Tại chu kỳ nạp đó, cờ ARM tự động xóa về 0 và tín hiệu
//      `loading` được kích hoạt ở mức cao để thông báo cho bộ báo thức (Alarm) tạm dừng so sánh.
//
// 3. Cơ chế chốt bóng phần cứng (Atomic Shadow Register Latching):
//    - Vấn đề xé số (Data Tearing / Race Condition): CPU giao tiếp qua bus MMIO 32-bit,
//      phải mất 2 chu kỳ đọc liên tiếp để lấy được đầy đủ thời gian (đọc ms trước, đọc ngày/thứ sau).
//      Nếu CPU đọc ms tại thời điểm 23:59:59.999, ngay sau đó đồng hồ nhảy sang ngày mới 00:00:00.000,
//      CPU đọc tiếp thanh ghi ngày sẽ lấy ngày mới (day + 1). Kết quả là CPU ghép thành
//      thời điểm sai hoàn toàn: 23:59:59.999 của ngày hôm sau!
//    - Giải pháp: Khi CPU phát tín hiệu đọc thanh ghi `A_MS_OF_DAY`, phần cứng tự động
//      "chụp ảnh" (latch) tức thời giá trị `{dow, day}` vào thanh ghi bóng `shadow`.
//      Ở lệnh kế tiếp, CPU đọc thanh ghi `A_DAY_SHADOW` để nhận lại đúng trạng thái đã chụp.
//      Cặp giá trị đọc được luôn đảm bảo tính nguyên tử (atomic) và đồng nhất thời điểm.
//
// 4. An toàn dữ liệu & Kiểm soát biên (Boundary Protection):
//    - Nếu người dùng nạp `SET_MS >= 86.400.000`, phần cứng tự động ép về 0 để tránh kẹt đếm.
//    - Nếu mã thứ `SET_DAY[18:16] == 3'd7` (mã không hợp lệ), phần cứng tự động chuyển thành 0 (Chủ Nhật).
//    - Sinh xung `tick_1s` chuẩn xác mỗi 1000 xung tick_ms kể từ lần nạp giờ gần nhất.
// ============================================================================

`timescale 1ns/1ps

module rtc #(
    parameter G_MS_PER_DAY = 86400000      // Số ms trong 1 ngày: 24 * 60 * 60 * 1000
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,        // Xung nhịp hệ thống 50 MHz
    input  wire        rst,        // Reset đồng bộ mức cao (Active-high Reset)
    input  wire        tick_ms,    // Xung nhịp 1 chu kỳ mỗi 1 ms (từ khối timebase)
    
    // Giao diện Bus MMIO
    input  wire [7:0]  bus_addr,   // Địa chỉ byte offset trong không gian ngoại vi RTC
    input  wire [31:0] bus_wdata,  // Bus dữ liệu ghi từ CPU
    input  wire        bus_we,     // Tín hiệu cho phép ghi MMIO (Write Enable)
    input  wire        bus_re,     // Tín hiệu cho phép đọc MMIO (Read Enable)
    output reg  [31:0] bus_rdata,  // Bus dữ liệu đọc trả về cho CPU

    // Các đường trạng thái thời gian xuất trực tiếp ra phần cứng SoC
    output reg  [26:0] ms,         // Mili-giây hiện tại trong ngày (0 .. 86.399.999)
    output reg  [15:0] day,        // Số ngày trôi qua kể từ mốc 01/01/2000 (0 .. 65.535)
    output reg  [2:0]  dow,        // Thứ trong tuần: 0=Chủ Nhật, 1=Thứ Hai, ..., 6=Thứ Bảy
    output wire        tick_1s,    // Xung nhịp 1 chu kỳ tại mỗi 1000 ms (chu kỳ 1 giây)
    output wire        loading     // Báo hiệu đang trong chu kỳ nạp giờ mới (chống báo thức oan)
);

    // ------------------------------------------------------------------------
    // ĐỊA CHỈ THANH GHI NGOẠI VI (MMIO REGISTER ADDRESS MAP)
    // ------------------------------------------------------------------------
    localparam A_MS_OF_DAY  = 8'h04,   // 0x04: Đọc ms trong ngày [26:0] (đồng thời chụp {dow, day} vào shadow)
               A_DAY_SHADOW = 8'h08,   // 0x08: Đọc thanh ghi bóng {dow[2:0], day[15:0]}
               A_SET_MS     = 8'h0C,   // 0x0C: Ghi giá trị ms mới muốn nạp [26:0]
               A_SET_DAY    = 8'h10,   // 0x10: Ghi giá trị {dow[2:0], day[15:0]} mới muốn nạp
               A_RTC_CTRL   = 8'h14;   // 0x14: Thanh ghi điều khiển (bit [0] = ARM: lên lịch nạp ở tick kế tiếp)

    // ------------------------------------------------------------------------
    // THANH GHI VÀ TÍN HIỆU NỘI BỘ (INTERNAL REGISTERS & SIGNALS)
    // ------------------------------------------------------------------------
    reg [26:0] set_ms;                 // Bộ đệm lưu trữ ms chuẩn bị nạp (chờ cờ ARM)
    reg [15:0] set_day;                // Bộ đệm lưu trữ ngày chuẩn bị nạp
    reg [2:0]  set_dow;                // Bộ đệm lưu trữ thứ chuẩn bị nạp
    reg        arm;                    // Cờ báo hiệu lệnh nạp giờ đã sẵn sàng kích hoạt
    reg [18:0] shadow;                 // Thanh ghi bóng chụp nguyên tử {dow[2:0], day[15:0]}
    reg [9:0]  c1s;                    // Bộ đếm 1000 ms để tạo xung tick_1s (0 .. 999)

    // Khử cảnh báo linter đối với các bit dữ liệu không sử dụng của bus ghi
    wire unused_ok = &{1'b0, bus_wdata[31:27]};

    // Tín hiệu loading kích hoạt trong đúng 1 chu kỳ có tick_ms và arm = 1
    assign loading = tick_ms && arm;

    // Tín hiệu tick_1s bật đúng ở mili-giây thứ 999 khi không có sự kiện nạp giờ
    assign tick_1s = tick_ms && !arm && (c1s == 10'd999);

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ: ĐẾM THỜI GIAN, NẠP GIỜ & GIAO TIẾP BUS MMIO
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            // Trạng thái khởi động mặc định: 00:00:00.000, Thứ Bảy (dow=6), Ngày 0
            ms        <= 27'd0;
            day       <= 16'd0;
            dow       <= 3'd6;
            set_ms    <= 27'd0;
            set_day   <= 16'd0;
            set_dow   <= 3'd0;
            arm       <= 1'b0;
            shadow    <= 19'd0;
            c1s       <= 10'd0;
            bus_rdata <= 32'd0;
        end else begin
            // ----------------------------------------------------------------
            // 1. TIẾN TRÌNH ĐẾM THỜI GIAN THỰC (TICK COUNTER)
            // ----------------------------------------------------------------
            if (tick_ms) begin
                if (arm) begin
                    // Có yêu cầu nạp giờ mới đã được ARM từ trước:
                    // Nạp nguyên tử toàn bộ các trường thời gian và xóa bộ đếm 1s
                    ms  <= set_ms;
                    day <= set_day;
                    dow <= set_dow;
                    c1s <= 10'd0;
                end else begin
                    // Đếm tiến mili-giây bình thường
                    c1s <= (c1s == 10'd999) ? 10'd0 : c1s + 10'd1;
                    
                    if (ms == G_MS_PER_DAY - 1) begin
                        // Thời khắc qua nửa đêm (23:59:59.999 -> 00:00:00.000)
                        ms  <= 27'd0;
                        day <= day + 16'd1;                          // Tăng ngày, tự động quay vòng 16-bit
                        dow <= (dow == 3'd6) ? 3'd0 : dow + 3'd1;   // Thứ Bảy -> Chủ Nhật
                    end else begin
                        ms <= ms + 27'd1;
                    end
                end
            end

            // ----------------------------------------------------------------
            // 2. GIAO DIỆN GHI BUS MMIO (BUS WRITE LOGIC)
            // ----------------------------------------------------------------
            if (bus_we) begin
                case (bus_addr)
                    A_SET_MS: begin
                        // Kiểm tra biên an toàn: nếu giá trị nạp >= 86.400.000 thì ép về 0
                        set_ms <= (bus_wdata[26:0] >= G_MS_PER_DAY) ? 27'd0 : bus_wdata[26:0];
                    end
                    A_SET_DAY: begin
                        set_day <= bus_wdata[15:0];
                        // Nếu mã thứ nhập vào là 7 (không hợp lệ) thì ép về 0 (Chủ Nhật)
                        set_dow <= (bus_wdata[18:16] == 3'd7) ? 3'd0 : bus_wdata[18:16];
                    end
                    A_RTC_CTRL: begin
                        // Bit 0 = ARM: Ghi 1 để lên lịch nạp ở tick_ms kế; ghi 0 để hủy lệnh nạp đang chờ
                        arm <= bus_wdata[0];
                    end
                    default: ;
                endcase
            end else if (tick_ms && arm) begin
                // Tự động xóa cờ ARM về 0 ngay sau khi chu kỳ nạp giờ hoàn tất
                arm <= 1'b0;
            end

            // ----------------------------------------------------------------
            // 3. GIAO DIỆN ĐỌC BUS MMIO & CHỐT BÓNG NGUYÊN TỬ (SHADOW LATCHING)
            // ----------------------------------------------------------------
            if (bus_re) begin
                case (bus_addr)
                    A_MS_OF_DAY: begin
                        // Trả về ms hiện tại đồng thời kích hoạt phần cứng chốt bóng tức thời {dow, day}
                        bus_rdata <= {5'd0, ms};
                        shadow    <= {dow, day};
                    end
                    A_DAY_SHADOW: begin
                        // Trả về bản sao nguyên tử {dow, day} đã được chốt ở lệnh đọc A_MS_OF_DAY trước đó
                        bus_rdata <= {13'd0, shadow};
                    end
                    A_RTC_CTRL: begin
                        // Trạng thái cờ ARM
                        bus_rdata <= {31'd0, arm};
                    end
                    default: begin
                        // Các thanh ghi chỉ ghi hoặc địa chỉ không ánh xạ trả về 0
                        bus_rdata <= 32'd0;
                    end
                endcase
            end
        end
    end

endmodule
