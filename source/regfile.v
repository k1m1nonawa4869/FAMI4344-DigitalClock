// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     regfile.v — Tập Thanh Ghi Đa Năng MIPS (Register File 32x32)
// CHUYÊN ĐỀ KTMT: Chương 04: Bộ Xử Lý Trung Tâm MIPS, Đường Dữ Liệu & Tập Thanh Ghi
// VAI TRÒ:        Khối Lưu Trữ Thanh Ghi Trung Tâm & Cơ Chế Chuyển Tiếp Nội Bộ (Bypassing)
// MÔ TẢ:          Module chứa tập 32 thanh ghi 32-bit ($0 .. $31) theo chuẩn kiến trúc MIPS:
//                 - 2 cổng đọc tổ hợp độc lập (ra1 -> rd1, ra2 -> rd2).
//                 - 1 cổng ghi đồng bộ tại sườn lên xung nhịp (wa, wd khi we = 1).
//                 - Thanh ghi $0 ($zero) cứng bằng 0x00000000 (không thể bị ghi đè).
//                 - Cơ chế Ghi-trước-Đọc-sau nội bộ (Internal Forwarding / Write-First Bypassing)
//                   khi G_BYPASS = 1 phục vụ giải quyết xung đột dữ liệu 1 chu kỳ trong CPU đường ống.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Cấu trúc Tập Thanh Ghi MIPS (MIPS 32x32-bit Register File):
//    - Kiến trúc MIPS quy định 32 thanh ghi đa năng ($0 đến $31), mỗi thanh ghi rộng 32 bit.
//    - Trong 1 chu kỳ thực thi lệnh (tầng ID), CPU cần đọc đồng thời tối đa 2 thanh ghi nguồn
//      (rs tại `ra1`, rt tại `ra2`) và chuẩn bị ghi kết quả vào 1 thanh ghi đích (rd hoặc rt tại `wa`).
//    - Do đó cấu trúc phần cứng bắt buộc phải là 2 Cổng Đọc Bất Đồng Bộ (Asynchronous 2-Read Ports)
//      và 1 Cổng Ghi Đồng Bộ (Synchronous 1-Write Port).
//
// 2. Quy Tắc Thanh Ghi $0 Cố Định (Hardware Hardwired Zero Register):
//    - Theo chuẩn ISA MIPS, thanh ghi $0 ($zero) luôn luôn có giá trị bằng 0 để làm mốc tham chiếu,
//      tạo hằng số 0, hoặc thực hiện các lệnh giả (Pseudoinstructions như `move $d, $s` = `addu $d, $s, $0`).
//    - Hiện thực phần cứng:
//        + Khi ghi: Điều kiện `if (we && wa != 5'd0)` ngăn chặn tuyệt đối việc ghi đè vào ô nhớ r[0].
//        + Khi đọc: Biểu thức `(ra == 5'd0) ? 32'd0 : ...` cưỡng bức đầu ra đọc luôn bằng 0x00000000.
//
// 3. Cơ Chế Ghi-Trước-Đọc-Sau Nội Bộ (Internal Write-First Forwarding / Bypassing):
//    - Xung đột cấu trúc / dữ liệu (Data Hazard giữa tầng WB và tầng ID):
//        Lệnh đi trước ở tầng Ghi lại (Write-Back - WB) đang ghi giá trị mới vào thanh ghi $k tại sườn lên clock.
//        Đồng thời, lệnh đi sau ở tầng Giải mã (Instruction Decode - ID) đang đọc thanh ghi $k trong cùng chu kỳ đó.
//    - Nếu không có mạch Bypass (G_BYPASS = 0): Lệnh đi sau sẽ đọc phải giá trị CŨ của thanh ghi $k
//      (vì giá trị mới chỉ thực sự cập nhật vào ô nhớ sau cạnh xung nhịp).
//    - Khi bật G_BYPASS = 1 (dùng cho CPU Pipeline G2):
//        `wire byp1 = (G_BYPASS != 0) && we && (wa == ra1);`
//        Nếu phát hiện địa chỉ ghi trùng địa chỉ đọc (`wa == ra1`), phần cứng đưa thẳng dữ liệu ghi `wd`
//        ra cổng đọc `rd1` ngay trong cùng chu kỳ tổ hợp (tương đương khái niệm ghi ở nửa đầu chu kỳ, đọc ở nửa sau).
//    - Lưu ý thiết kế: Trong CPU đơn chu kỳ (G1), bắt buộc đặt G_BYPASS = 0 vì cổng ghi và cổng đọc
//      thuộc về cùng một lệnh; nếu bypass sẽ tạo ra vòng lặp tổ hợp (Combinational Loop) gây lỗi mô phỏng và tổng hợp.
// ============================================================================

`timescale 1ns/1ps

module regfile #(
    parameter G_BYPASS = 1              // 1 = Bật chuyển tiếp nội bộ (cho CPU Pipeline); 0 = Tắt (cho CPU Đơn chu kỳ)
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,             // Xung nhịp hệ thống
    input  wire        rst,             // Reset đồng bộ mức cao (Active-high Reset)
    
    // Cổng ghi đồng bộ (Synchronous Write Port)
    input  wire        we,              // Tín hiệu cho phép ghi (Write Enable)
    input  wire [4:0]  wa,              // Địa chỉ thanh ghi đích cần ghi (0 .. 31)
    input  wire [31:0] wd,              // Dữ liệu 32-bit cần ghi vào thanh ghi wa
    
    // Cổng đọc 1 bất đồng bộ (Asynchronous Read Port 1 - Toán hạng rs)
    input  wire [4:0]  ra1,             // Địa chỉ thanh ghi nguồn 1 (0 .. 31)
    output wire [31:0] rd1,             // Dữ liệu đọc ra từ thanh ghi ra1
    
    // Cổng đọc 2 bất đồng bộ (Asynchronous Read Port 2 - Toán hạng rt)
    input  wire [4:0]  ra2,             // Địa chỉ thanh ghi nguồn 2 (0 .. 31)
    output wire [31:0] rd2              // Dữ liệu đọc ra từ thanh ghi ra2
);

    // ------------------------------------------------------------------------
    // MẢNG LƯU TRỮ 32 THANH GHI 32-BIT (STORAGE ARRAY)
    // ------------------------------------------------------------------------
    reg [31:0] r [0:31];                // 32 thanh ghi vật lý (r[0] không bao giờ được ghi)
    integer i;

    // ------------------------------------------------------------------------
    // TIẾN TRÌNH GHI ĐỒNG BỘ TẠI SƯỜN LÊN CLOCK (SYNCHRONOUS WRITE)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            // Reset toàn bộ 32 thanh ghi về 0x00000000
            for (i = 0; i < 32; i = i + 1)
                r[i] <= 32'd0;
        end else if (we && (wa != 5'd0)) begin
            // Chỉ ghi khi we=1 và địa chỉ khác 0 (bảo vệ thanh ghi $zero)
            r[wa] <= wd;
        end
    end

    // ------------------------------------------------------------------------
    // LOGIC CHUYỂN TIẾP NỘI BỘ (INTERNAL FORWARDING / BYPASS LOGIC)
    // ------------------------------------------------------------------------
    // Phát hiện xung đột: Đang ghi vào thanh ghi wa trùng với thanh ghi đọc ra1 hoặc ra2
    wire byp1 = (G_BYPASS != 0) && we && (wa == ra1);
    wire byp2 = (G_BYPASS != 0) && we && (wa == ra2);

    // ------------------------------------------------------------------------
    // ĐỌC BẤT ĐỒNG BỘ VỚI ƯU TIÊN $ZERO VÀ BYPASS
    // ------------------------------------------------------------------------
    // Ưu tiên 1: Đọc $0 luôn luôn trả về 32'd0.
    // Ưu tiên 2: Nếu có bypass, trả về dữ liệu mới wd ngay lập tức.
    // Ưu tiên 3: Đọc dữ liệu từ mảng thanh ghi r[ra].
    assign rd1 = (ra1 == 5'd0) ? 32'd0 : (byp1 ? wd : r[ra1]);
    assign rd2 = (ra2 == 5'd0) ? 32'd0 : (byp2 ? wd : r[ra2]);

endmodule
