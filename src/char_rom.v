// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     char_rom.v — Bảng Tra Mã Ký Tự Sang LED 7 Đoạn (Character ROM)
// CHUYÊN ĐỀ KTMT: Chương 02: Hệ Đếm & Bảng Tra Cứu Phần Cứng (Look-Up Tables - LUT)
// VAI TRÒ:        Bộ Giải Mã Ký Tự Phần Cứng Sang Mã 7 Đoạn (Hardware Character Decoder)
// MÔ TẢ:          Module tổ hợp chuyển đổi mã ký tự 5-bit (0x00 .. 0x1F) sang 7 đoạn
//                 gfedcba (bit 0 = đoạn a, bit 6 = đoạn g; mức 1 = sáng đoạn LED).
//                 - Mã 0x0 .. 0xF: Tương ứng 16 chữ số Hex (0..9, A..F) khớp trực tiếp
//                   với kết quả lệnh bcd trong tập lệnh MIPS của SoC.
//                 - Mã 0x10 .. 0x19: Các chữ cái và ký hiệu đặc biệt ("H", "L", "n", "o",
//                   "P", "r", "S", "t", "U", "-") phục vụ các chế độ đồng hồ.
//                 - Mã 0x1A .. 0x1F: Ký tự trống (tắt toàn bộ các đoạn).
// ============================================================================

`timescale 1ns/1ps

module char_rom (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire [4:0] code,   // Mã ký tự đầu vào 5-bit (0 .. 31)
    output reg  [6:0] seg     // Đầu ra 7 đoạn: [6:0] = gfedcba (bit 0 = a .. bit 6 = g)
);

    // ------------------------------------------------------------------------
    // BẢNG GIẢI MÃ TỔ HỢP (COMBINATIONAL DECODER TABLE)
    // ------------------------------------------------------------------------
    // Sơ đồ bố trí các đoạn LED 7 thanh chuẩn:
    //         aaa 
    //        f   b
    //         ggg 
    //        e   c
    //         ddd   (dp)
    // ------------------------------------------------------------------------
    always @* begin
        case (code)
            // Nhóm chữ số Hex (0x00 .. 0x0F)
            5'h00: seg = 7'h3F;  // '0': a,b,c,d,e,f sáng (011_1111)
            5'h01: seg = 7'h06;  // '1': b,c sáng (000_0110)
            5'h02: seg = 7'h5B;  // '2': a,b,d,e,g sáng (101_1011)
            5'h03: seg = 7'h4F;  // '3': a,b,c,d,g sáng (100_1111)
            5'h04: seg = 7'h66;  // '4': b,c,f,g sáng (110_0110)
            5'h05: seg = 7'h6D;  // '5': a,c,d,f,g sáng (110_1101)
            5'h06: seg = 7'h7D;  // '6': a,c,d,e,f,g sáng (111_1101)
            5'h07: seg = 7'h07;  // '7': a,b,c sáng (000_0111)
            5'h08: seg = 7'h7F;  // '8': cả 7 đoạn cùng sáng (111_1111)
            5'h09: seg = 7'h6F;  // '9': a,b,c,d,f,g sáng (110_1111)
            5'h0A: seg = 7'h77;  // 'A': a,b,c,e,f,g sáng (111_0111)
            5'h0B: seg = 7'h7C;  // 'b': c,d,e,f,g sáng (111_1100)
            5'h0C: seg = 7'h39;  // 'C': a,d,e,f sáng (011_1001)
            5'h0D: seg = 7'h5E;  // 'd': b,c,d,e,g sáng (101_1110)
            5'h0E: seg = 7'h79;  // 'E': a,d,e,f,g sáng (111_1001)
            5'h0F: seg = 7'h71;  // 'F': a,e,f,g sáng (111_0001)
            
            // Nhóm chữ cái & ký hiệu giao diện người dùng (0x10 .. 0x19)
            5'h10: seg = 7'h76;  // 'H': b,c,e,f,g sáng (111_0110)
            5'h11: seg = 7'h38;  // 'L': d,e,f sáng (011_1000)
            5'h12: seg = 7'h54;  // 'n': c,e,g sáng (101_0100)
            5'h13: seg = 7'h5C;  // 'o': c,d,e,g sáng (101_1100)
            5'h14: seg = 7'h73;  // 'P': a,b,e,f,g sáng (111_0011)
            5'h15: seg = 7'h50;  // 'r': e,g sáng (101_0000)
            5'h16: seg = 7'h6D;  // 'S': giống chữ số 5 (110_1101)
            5'h17: seg = 7'h78;  // 't': d,e,f,g sáng (111_1000)
            5'h18: seg = 7'h3E;  // 'U': b,c,d,e,f sáng (011_1110)
            5'h19: seg = 7'h40;  // '-': chỉ đoạn g giữa sáng (100_0000)
            5'h1B: seg = 7'h37;  // 'M': a,b,c,e,f sáng (011_0111)
            5'h1C: seg = 7'h1C;  // 'W': c,d,e sáng (001_1100)
            5'h1D: seg = 7'h7D;  // 'G': a,c,d,e,f,g sáng (111_1101, kiểu chữ số 6 chuẩn hóa ký tự)
            
            // Nhóm ký tự trống (0x1A, 0x1E .. 0x1F)
            default: seg = 7'h00; // Tắt toàn bộ các đoạn (khoảng trắng)
        endcase
    end

endmodule
