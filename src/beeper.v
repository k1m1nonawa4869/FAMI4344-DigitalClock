// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     beeper.v — Khối Phát Âm Tần PWM & Chuỗi Mẫu Tiếng Bíp
// CHUYÊN ĐỀ KTMT: Chương 07: Hệ thống Vào/Ra, Điều Chế Xung PWM & Bộ Tạo Nhịp Âm
// VAI TRÒ:        Bộ Tạo Âm Thanh Còi Báo Động & Phát Mẫu Nhịp Điệu (PWM Beeper)
// MÔ TẢ:          Module phát âm thanh còi chip (Buzzer/Beeper):
//                 - Bộ tạo sóng vuông âm tần PWM với nửa chu kỳ cấu hình được qua BEEP_FREQ.
//                 - Bộ đếm nhịp mẫu 16 khe x 64 ms (BEEP_PATTERN) tạo các kiểu chuông đa dạng.
//                 - Hỗ trợ chế độ lặp lại vô hạn (Repeat bit).
//                 - Kích hoạt phần cứng trực tiếp (hw_trig) khi bộ đếm lùi chạm 0 (TMR_ZERO).
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Nguyên lý Tạo Sóng Vuông Âm Tần (PWM Square-Wave Synthesis):
//    - Để phát âm thanh ra loa gốm hoặc còi piezo, chân điều khiển cần cấp sóng vuông đối xứng (Duty Cycle 50%).
//    - Tần số âm thanh phát ra phụ thuộc vào nửa chu kỳ sóng (số chu kỳ xung nhịp `freq`):
//          f_audio = f_clk / (2 * freq)
//    - Ở xung nhịp hệ thống f_clk = 50 MHz:
//        + Mặc định sau reset: freq = 12.500 chu kỳ ==> f_audio = 50.000.000 / (2 * 12.500) = 2.000 Hz (2 kHz).
//        + Đây là tần số âm thanh cộng hưởng phổ biến của các còi chip điện tử.
//        + Khi freq = 0: Tắt sóng vuông hoàn toàn (im lặng).
//
// 2. Bộ Tạo Mẫu Nhịp Điệu 16 Khe (16-Slot Rhythm Pattern Sequencer):
//    - Nhịp điệu phát còi được chia thành 16 khe thời gian liên tiếp (Slot 0 .. 15), mỗi khe dài đúng 64 ms
//      (đo bằng 64 xung tick_ms). Tổng độ dài 1 chu kỳ mẫu hoàn chỉnh: 16 * 64 ms = 1.024 ms (~1 giây).
//    - Thanh ghi mẫu BEEP_PATTERN (17-bit):
//        + Bit [15:0]: Mỗi bit tương ứng với 1 khe 64 ms. Bit k = 1 nghĩa là phát âm trong khe k, bit k = 0 là ngắt nghỉ.
//          Ví dụ: pat = 16'h0F0F = 0000_1111_0000_1111b ==> Kêu 256 ms, nghỉ 256 ms, kêu 256 ms, nghỉ 256 ms.
//        + Bit [16]  : Cờ lặp lại (REPEAT). Nếu bit 16 = 1, sau khi chạy hết khe 15 sẽ tự động quay lại khe 0;
//          nếu bit 16 = 0, sau khe 15 sẽ tự động xóa mẫu về 0 và dừng hẳn.
//
// 3. Kích Hoạt Phần Cứng Tức Thời & Ưu Tiên Sự Kiện (Hardware Trigger & Priority):
//    - Tín hiệu `hw_trig` từ khối countdown_core tự động nạp mẫu báo động `P_ALARM = 17'h10F0F` (kêu dồn dập kèm lặp lại)
//      ngay khi chạm 00:00:00 mà không cần CPU phải can thiệp.
//    - Nếu trong cùng chu kỳ CPU ghi mẫu mới và có xung `hw_trig` phần cứng, tín hiệu `hw_trig` chiếm quyền ưu tiên cao hơn,
//      đảm bảo tiếng chuông hết giờ không bao giờ bị lệnh phần mềm vô tình ghi đè làm mất.
// ============================================================================

`timescale 1ns/1ps

module beeper (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,        // Xung nhịp hệ thống 50 MHz
    input  wire        rst,        // Reset đồng bộ mức cao (Active-high Reset)
    input  wire        tick_ms,    // Xung nhịp 1 ms từ bộ chia timebase
    input  wire        hw_trig,    // Tín hiệu kích hoạt còi từ phần cứng (khi hết giờ Countdown)
    
    // Giao diện Bus MMIO
    input  wire [7:0]  bus_addr,   // Địa chỉ byte offset trong không gian ngoại vi
    input  wire [31:0] bus_wdata,  // Dữ liệu ghi từ CPU
    input  wire        bus_we,     // Tín hiệu ghi MMIO (Write Enable)
    
    // Đầu ra âm thanh
    output wire        beep,       // Chân xuất sóng vuông PWM điều khiển loa/còi
    output wire        sounding    // Tín hiệu báo khe hiện tại đang có âm thanh (phục vụ quan sát/testbench)
);

    // ------------------------------------------------------------------------
    // ĐỊA CHỈ THANH GHI NGOẠI VI (MMIO REGISTER ADDRESS MAP)
    // ------------------------------------------------------------------------
    localparam A_FREQ = 8'h84,          // 0x84: Nửa chu kỳ sóng vuông [15:0] (Mặc định 12500 tương ứng 2 kHz)
               A_PAT  = 8'h88;          // 0x88: Mẫu chuông [16:0] ([15:0] = 16 khe x 64 ms; [16] = REPEAT)

    // Mẫu chuông báo động hết giờ mặc định: 0x10F0F (kêu-kêu-nghỉ-nghỉ lặp lại)
    localparam [16:0] P_ALARM = 17'h10F0F;

    // ------------------------------------------------------------------------
    // THANH GHI VÀ TÍN HIỆU NỘI BỘ (INTERNAL REGISTERS & SIGNALS)
    // ------------------------------------------------------------------------
    reg [15:0] freq;                    // Số chu kỳ xung nhịp cho nửa chu kỳ sóng âm
    reg [15:0] wc;                      // Bộ đếm chu kỳ sóng vuông PWM (0 .. freq - 1)
    reg [16:0] pat;                     // Thanh ghi mẫu âm thanh 17-bit
    reg [3:0]  slot;                    // Chỉ số khe thời gian hiện tại (0 .. 15)
    reg [5:0]  tc;                      // Bộ đếm mili-giây trong 1 khe (0 .. 63)
    reg        sq;                      // Trạng thái mức logic hiện tại của sóng vuông

    // Giải mã ghi bus từ CPU
    wire w_pat = bus_we && (bus_addr == A_PAT);
    // Điều kiện nạp mẫu âm thanh: có xung kích hoạt phần cứng HOẶC CPU ghi mẫu mới
    wire load  = hw_trig || w_pat;

    // Trạng thái khe hiện tại có phát âm hay không
    assign sounding = pat[{1'b0, slot}] && (freq != 16'd0);
    // Tín hiệu âm thanh xuất ra chân loa: Chỉ bật khi khe có âm AND sóng vuông ở mức cao
    assign beep     = sounding && sq;

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH TUẦN TỰ (SEQUENTIAL LOGIC)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            freq <= 16'd12500;          // Tần số mặc định 2 kHz ở 50 MHz
            pat  <= 17'd0;              // Mặc định tắt tiếng
            slot <= 4'd0;
            tc   <= 6'd0;
            wc   <= 16'd0;
            sq   <= 1'b0;
        end else begin
            // 1. Cập nhật tần số âm thanh từ CPU
            if (bus_we && (bus_addr == A_FREQ)) begin
                freq <= bus_wdata[15:0];
            end

            // 2. Quản lý chuỗi mẫu âm thanh 16 khe x 64 ms
            if (load) begin
                // hw_trig chiếm quyền ưu tiên nếu xảy ra cùng chu kỳ với CPU ghi mẫu
                pat  <= hw_trig ? P_ALARM : bus_wdata[16:0];
                slot <= 4'd0;           // Bắt đầu lại ngay từ khe 0
                tc   <= 6'd0;
            end else if (tick_ms && (pat[15:0] != 16'd0)) begin
                tc <= tc + 6'd1;
                if (tc == 6'd63) begin
                    // Đủ 64 ms: Chuyển sang khe kế tiếp
                    slot <= slot + 4'd1;
                    // Hết khe 15: Nếu không bật cờ REPEAT (bit 16) thì dừng hẳn
                    if ((slot == 4'd15) && !pat[16]) begin
                        pat <= 17'd0;
                    end
                end
            end

            // 3. Bộ tạo sóng vuông PWM đối xứng
            if (load || !sounding) begin
                // Reset pha sóng vuông khi nạp mẫu mới hoặc khi đang trong khe ngắt nghỉ
                wc <= 16'd0;
                sq <= 1'b0;
            end else if (wc == freq - 16'd1) begin
                wc <= 16'd0;
                sq <= !sq;              // Đủ thời gian nửa chu kỳ: Đảo mức sóng vuông
            end else begin
                wc <= wc + 16'd1;
            end
        end
    end

    // Khử cảnh báo linter đối với các bit dữ liệu ghi không dùng
    wire unused_ok = &{1'b0, bus_wdata[31:17]};

endmodule
