// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     alu.v — Đơn vị Số học và Logic 32-bit (ALU - Arithmetic Logic Unit)
// CHUYÊN ĐỀ KTMT: Chương 03: Số học máy tính & Chương 04: Kiến trúc tập lệnh ISA
// VAI TRÒ:        Khối Tính Toán Số Học & Logic Phần Cứng (ALU Hardware Core)
// MÔ TẢ:          Mạch tổ hợp 32-bit thực hiện các phép tính số học bù 2 (cộng, trừ),
//                 phép toán logic (AND, OR, XOR), so sánh có dấu (SLT) an toàn tràn số,
//                 và các phép dịch bit (SLL, SRA). Xuất cờ Zero phục vụ lệnh rẽ nhánh.
// ============================================================================

`timescale 1ns/1ps

module alu (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire [31:0] a,        // Toán hạng thứ nhất (thường lấy từ thanh ghi rs)
    input  wire [31:0] b,        // Toán hạng thứ hai (lấy từ rt hoặc hằng số mở rộng dấu immediate)
    input  wire [4:0]  shamt,    // Số bit dịch (Shift Amount - 5 bit trong trường shamt của lệnh R-type)
    input  wire [3:0]  ctl,      // Mã điều khiển phép tính ALU (ALU Control Signal từ Control Unit)
    output reg  [31:0] y,        // Kết quả đầu ra 32-bit
    output wire        zero      // Cờ Zero = 1 khi kết quả y == 0 (dùng cho lệnh rẽ nhánh beq/bne)
);

    // ------------------------------------------------------------------------
    // MÃ ĐIỀU KHIỂN ALU (ALU OPERATION CODES) - Khớp với bảng giải mã Control
    // ------------------------------------------------------------------------
    localparam ALU_ADD = 4'd0;   // Cộng số học 32-bit: y = a + b
    localparam ALU_SUB = 4'd1;   // Trừ số học 32-bit: y = a - b
    localparam ALU_AND = 4'd2;   // Logic AND từng bit: y = a & b
    localparam ALU_OR  = 4'd3;   // Logic OR từng bit: y = a | b
    localparam ALU_XOR = 4'd4;   // Logic XOR từng bit: y = a ^ b
    localparam ALU_SLT = 4'd5;   // So sánh có dấu: y = (a < b) ? 1 : 0
    localparam ALU_SLL = 4'd6;   // Dịch trái logic: y = b << shamt
    localparam ALU_SRA = 4'd7;   // Dịch phải số học (bảo toàn bit dấu): y = b >>> shamt

    // ------------------------------------------------------------------------
    // NGUYÊN LÝ SỐ HỌC BÙ 2 VÀ BẢO VỆ CHỐNG TRÀN SỐ TRONG PHÉP SO SÁNH SLT:
    // ------------------------------------------------------------------------
    // Phép trừ diff = a - b trong hệ bù 2 tương đương: diff = a + (~b + 1).
    // Nếu chỉ dựa vào bit dấu diff[31] để kết luận (a < b) sẽ gặp lỗi khi TRÀN SỐ (Overflow):
    //   Ví dụ: a = -2^31 (0x80000000 - số âm nhỏ nhất), b = 1 (số dương).
    //   Ta có a < b là ĐÚNG. Nhưng phép tính: a - b = -2^31 - 1 bị tràn số thành +2^31 - 1 (số dương).
    //   Khi đó diff[31] = 0 (kết quả dương) dẫn đến kết luận SAI là a > b!
    //
    // GIẢI PHÁP PHẦN CỨNG CHUẨN MỰC (Hennessy & Patterson):
    // 1. Nếu 2 số KHÁC DẤU (a[31] != b[31]): Không bao giờ xảy ra tràn số trong so sánh.
    //    Số âm luôn nhỏ hơn số dương, do đó: a < b khi và chỉ khi a là số âm (a[31] == 1).
    // 2. Nếu 2 số CÙNG DẤU (a[31] == b[31]): Phép trừ a - b KHÔNG BAO GIỜ bị tràn số.
    //    Bit dấu của hiệu diff[31] phản ánh chính xác kết quả so sánh.
    // ------------------------------------------------------------------------
    wire [31:0] diff = a - b;
    wire        lt   = (a[31] != b[31]) ? a[31] : diff[31];

    // ------------------------------------------------------------------------
    // KHỐI LOGIC TỔ HỢP THỰC HIỆN PHÉP TÍNH (COMBINATIONAL DATAPATH)
    // ------------------------------------------------------------------------
    always @* begin
        case (ctl)
            ALU_ADD: y = a + b;                          // Cộng số học 32-bit
            ALU_SUB: y = diff;                           // Trừ số học 32-bit
            ALU_AND: y = a & b;                          // Phép toán logic AND từng bit
            ALU_OR:  y = a | b;                          // Phép toán logic OR từng bit
            ALU_XOR: y = a ^ b;                          // Phép toán logic XOR từng bit
            ALU_SLT: y = {31'd0, lt};                    // Đặt 1 nếu a < b (có dấu), ngược lại là 0
            ALU_SLL: y = b << shamt;                     // Dịch trái logic biến b đi shamt bit
            ALU_SRA: y = $unsigned($signed(b) >>> shamt);// Dịch phải số học nhân bản bit dấu MSB
            default: y = 32'd0;                          // Chống Accidental Latch: luôn có giá trị mặc định
        endcase
    end

    // ------------------------------------------------------------------------
    // BÁO HIỆU CỜ ZERO (Dùng cho lệnh beq: branch when zero = 1, bne: zero = 0)
    // ------------------------------------------------------------------------
    assign zero = (y == 32'd0);

endmodule
