// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     hazard.v — Đơn Vị Phát Hiện Xung Đột & Chuyển Tiếp Dữ Liệu
// CHUYÊN ĐỀ KTMT: Chương 05: Kỹ Thuật Đường Ống, Xung Đột (Hazards) & Forwarding
// VAI TRÒ:        Khối Kiểm Soát Xung Đột Đường Ống CPU MIPS 5 Tầng (Hazard Unit)
// MÔ TẢ:          Module tổ hợp phát hiện và giải quyết 3 loại xung đột đường ống:
//                 - Data Hazard (RAW): Mạch chuyển tiếp dữ liệu (Forwarding) 2 tầng từ EX/MEM
//                   và MEM/WB về tầng EX cho 2 toán hạng ALU (fwd_a, fwd_b).
//                 - Load-Use Hazard: Phát hiện lệnh lw liền trước lệnh sử dụng dữ liệu,
//                   kích hoạt chèn 1 chu kỳ dừng (stall_lu) và chèn bong bóng (bubble).
//                 - Control Hazard (Branch): Phát hiện rẽ nhánh thành công ở tầng EX (taken),
//                   kích hoạt xóa lệnh nạp sai ở 2 tầng trước (flush).
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Phân Tích Xung Đột Dữ Liệu (Data Hazards - RAW):
//    - Xảy ra khi một lệnh ở tầng sau cần đọc thanh ghi mà lệnh ở tầng trước chưa kịp ghi về RegFile.
//    - Cơ chế Chuyển Tiếp Dữ Liệu (Data Forwarding / Bypassing):
//        + Nguồn cấp 1 (Tầng EX/MEM): Kết quả vừa tính xong ở đầu ra ALU của lệnh đi trước 1 nhịp.
//        + Nguồn cấp 2 (Tầng MEM/WB): Dữ liệu đọc từ bộ nhớ hoặc kết quả ALU của lệnh đi trước 2 nhịp.
//    - Điều kiện Forwarding cho Toán hạng A (tương tự cho Toán hạng B):
//        + Ưu tiên 1 (EX/MEM Hazard - mới nhất):
//          `if (exmem_reg_write && exmem_dst != 0 && exmem_dst == idex_rs) fwd_a = 2'b10;`
//        + Ưu tiên 2 (MEM/WB Hazard):
//          `else if (memwb_reg_write && memwb_dst != 0 && memwb_dst == idex_rs) fwd_a = 2'b01;`
//        + Không có xung đột:
//          `else fwd_a = 2'b00; // Sử dụng giá trị thanh ghi đọc từ tầng ID`
//    - Lưu ý: Điều kiện `dst != 0` bắt buộc vì thanh ghi $0 ($zero) trong MIPS luôn bằng 0, không được forward.
//
// 2. Xung Đột Nạp Dữ Liệu - Sử Dụng (Load-Use Data Hazard):
//    - Lệnh đọc bộ nhớ `lw` chỉ có dữ liệu hợp lệ ở cuối tầng MEM. Do đó, nếu lệnh kế tiếp ở tầng EX
//      cần ngay dữ liệu này, mạch Forwarding không thể chuyển ngược thời gian từ cuối MEM về đầu EX.
//    - Bắt buộc phải dừng (Stall) CPU đúng 1 chu kỳ:
//          `stall_lu = idex_mem_read && (idex_dst != 0) && ifid_valid &&`
//          `           ((ifid_uses_rs && idex_dst == ifid_rs) || (ifid_uses_rt && idex_dst == ifid_rt));`
//    - Khi stall_lu = 1: Giữ nguyên PC và thanh ghi tầng IF/ID, đồng thời chèn lệnh NOP (bong bóng) vào ID/EX.
//    - Tối ưu hóa: Chỉ xét các thanh ghi mà lệnh ở ID THỰC SỰ đọc (`ifid_uses_rs`, `ifid_uses_rt`),
//      tránh dừng oan cho các lệnh I-type như `addiu` (không đọc rt).
//
// 3. Xung Đột Điều Khiển (Control / Branch Hazards):
//    - Quyết định rẽ nhánh (`beq`, `bne`, `j`, `jal`, `jr`) được giải quyết tại tầng EX.
//    - Nếu rẽ nhánh thành công (`taken = 1`): 2 lệnh đã được nạp ở tầng IF và ID là các lệnh nạp sai.
//    - Mạch kích hoạt `flush = taken` để xóa toàn bộ các thanh ghi trung gian IF/ID và ID/EX thành NOP,
//      chịu hình phạt rẽ nhánh (Branch Penalty) đúng 2 chu kỳ clock.
// ============================================================================

`timescale 1ns/1ps

module hazard (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    // Tín hiệu từ tầng giải mã ID (thanh ghi IF/ID)
    input  wire       ifid_valid,      // Lệnh ở tầng ID có hợp lệ không (1 = lệnh thật, 0 = bong bóng)
    input  wire [4:0] ifid_rs,         // Thanh ghi nguồn rs của lệnh ở tầng ID
    input  wire [4:0] ifid_rt,         // Thanh ghi nguồn rt của lệnh ở tầng ID
    input  wire       ifid_uses_rs,    // Cờ báo lệnh ở tầng ID thực sự đọc thanh ghi rs
    input  wire       ifid_uses_rt,    // Cờ báo lệnh ở tầng ID thực sự đọc thanh ghi rt
    
    // Tín hiệu từ tầng thực thi EX (thanh ghi ID/EX)
    input  wire       idex_mem_read,   // Lệnh ở tầng EX là lệnh đọc bộ nhớ (lw)
    input  wire [4:0] idex_dst,        // Thanh ghi đích của lệnh ở tầng EX (0 = không ghi)
    input  wire [4:0] idex_rs,         // Thanh ghi nguồn rs của lệnh ở tầng EX (cần nhận forwarding)
    input  wire [4:0] idex_rt,         // Thanh ghi nguồn rt của lệnh ở tầng EX (cần nhận forwarding)
    
    // Tín hiệu từ tầng truy xuất bộ nhớ MEM (thanh ghi EX/MEM)
    input  wire       exmem_reg_write, // Lệnh ở tầng MEM có ghi thanh ghi đích (RegWrite)
    input  wire [4:0] exmem_dst,       // Thanh ghi đích của lệnh ở tầng MEM
    
    // Tín hiệu từ tầng ghi lại WB (thanh ghi MEM/WB)
    input  wire       memwb_reg_write, // Lệnh ở tầng WB có ghi thanh ghi đích (RegWrite)
    input  wire [4:0] memwb_dst,       // Thanh ghi đích của lệnh ở tầng WB
    
    // Tín hiệu điều khiển rẽ nhánh
    input  wire       taken,           // Quyết định rẽ nhánh/nhảy thành công tại tầng EX
    
    // Các tín hiệu điều khiển giải quyết xung đột đầu ra
    output wire       stall_lu,        // Tín hiệu chèn 1 chu kỳ dừng do xung đột Load-Use
    output wire       flush,           // Tín hiệu xóa bỏ 2 lệnh nạp sai khi rẽ nhánh thành công
    output reg  [1:0] fwd_a,           // Mux chọn nguồn dữ liệu Forwarding cho toán hạng A của ALU
    output reg  [1:0] fwd_b            // Mux chọn nguồn dữ liệu Forwarding cho toán hạng B của ALU
);

    // ------------------------------------------------------------------------
    // LOGIC PHÁT HIỆN LOAD-USE HAZARD & RẼ NHÁNH
    // ------------------------------------------------------------------------
    // Chèn Stall khi: Lệnh tầng EX là lw, ghi vào thanh ghi khác 0, và lệnh tầng ID
    // hợp lệ đang thực sự cần đọc chính thanh ghi đó.
    assign stall_lu = idex_mem_read && (idex_dst != 5'd0) && ifid_valid &&
                      ((ifid_uses_rs && (idex_dst == ifid_rs)) || 
                       (ifid_uses_rt && (idex_dst == ifid_rt)));

    // Xóa đường ống (Flush) 2 tầng IF/ID và ID/EX khi nhánh nhảy thật sự
    assign flush = taken;

    // ------------------------------------------------------------------------
    // LOGIC CHUYỂN TIẾP DỮ LIỆU TỔ HỢP (FORWARDING UNIT)
    // ------------------------------------------------------------------------
    always @* begin
        // 1. Chuyển tiếp cho Toán hạng A (ALU Operand A):
        // Ưu tiên 1: Lệnh ở tầng MEM (đi trước 1 nhịp, dữ liệu mới nhất)
        if (exmem_reg_write && (exmem_dst != 5'd0) && (exmem_dst == idex_rs)) begin
            fwd_a = 2'b10; // Lấy tắt kết quả từ thanh ghi EX/MEM
        end
        // Ưu tiên 2: Lệnh ở tầng WB (đi trước 2 nhịp)
        else if (memwb_reg_write && (memwb_dst != 5'd0) && (memwb_dst == idex_rs)) begin
            fwd_a = 2'b01; // Lấy tắt kết quả từ thanh ghi MEM/WB
        end
        // Không có xung đột: Dùng dữ liệu đọc từ RegFile ở tầng ID
        else begin
            fwd_a = 2'b00;
        end

        // 2. Chuyển tiếp cho Toán hạng B (ALU Operand B):
        // Tương tự toán hạng A nhưng so sánh với thanh ghi nguồn rt
        if (exmem_reg_write && (exmem_dst != 5'd0) && (exmem_dst == idex_rt)) begin
            fwd_b = 2'b10; // Lấy tắt kết quả từ thanh ghi EX/MEM
        end else if (memwb_reg_write && (memwb_dst != 5'd0) && (memwb_dst == idex_rt)) begin
            fwd_b = 2'b01; // Lấy tắt kết quả từ thanh ghi MEM/WB
        end else begin
            fwd_b = 2'b00;
        end
    end

endmodule
