// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     control.v — Khối Điều Khiển Trung Tâm & Giải Mã Lệnh (Control Unit)
// CHUYÊN ĐỀ KTMT: Chương 04: Khối Điều Khiển Lệnh Đơn Chu Kỳ & Đường Ống MIPS
// VAI TRÒ:        Bộ Giải Mã Vi Lệnh Tập Trung & Điều Khiển Đường Dữ Liệu (Decoder)
// MÔ TẢ:          Module tổ hợp giải mã lệnh 32-bit thành 16 tín hiệu điều khiển đường dữ liệu:
//                 - Hỗ trợ 28 lệnh MIPS cốt lõi (R-type, I-type, J-type, mở rộng BCD, MULDIV, CP0).
//                 - Sinh tín hiệu chọn thanh ghi đích (dst), mở rộng dấu (ext), mã ALU (alu_ctl).
//                 - Điều khiển đọc/ghi bộ nhớ (mem_read, mem_write), rẽ nhánh (branch), nhảy (jump).
//                 - Báo tín hiệu phụ thuộc toán hạng (uses_rs, uses_rt) cho khối Hazard Detection.
//                 - Mã lệnh không hợp lệ (Invalid) tự động phát valid = 0 và vô hiệu hóa mọi tác động ghi.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Phân Loại Khung Định Dạng Lệnh MIPS (MIPS Instruction Formats):
//    - Lệnh R-type (Register): opcode = 6'h00. Định danh chức năng chi tiết qua trường funct (6-bit).
//        Bao gồm: addu, subu, and, or, xor, slt, sll, sra, jr, div, mfhi, mflo.
//    - Lệnh I-type (Immediate): opcode != 0. Chứa hằng số 16-bit (imm16).
//        Bao gồm: addiu, slti, andi, ori, lui, lw, sw, beq, bne.
//    - Lệnh J-type (Jump): opcode = 0x02 (j), 0x03 (jal). Chứa địa chỉ mục tiêu 26-bit (target26).
//    - Nhóm SPECIAL2 (opcode = 6'h1C): Các lệnh mở rộng phục vụ đồ án:
//        + funct = 6'h02: `mul rd, rs, rt` (nhân 32-bit lấy 32-bit thấp vào rd).
//        + funct = 6'h10: `bcd rd, rs` (chuyển đổi nhị phân sang 8 chữ số BCD phần cứng).
//    - Nhóm COP0 (opcode = 6'h10): Các lệnh giao tiếp thanh ghi điều khiển ngắt/ngoại lệ:
//        + `mfc0 rt, rd` (đọc thanh ghi CP0 vào rt).
//        + `mtc0 rt, rd` (ghi rt vào thanh ghi CP0).
//        + `eret` (quay về sau khi xử lý ngắt, khôi phục PC từ EPC).
//
// 2. Chức Năng 16 Tín Hiệu Điều Khiển Đường Dữ Liệu (Control Signals):
//    - reg_write  : 1 = Cho phép ghi kết quả vào tập thanh ghi RegFile.
//    - dst[1:0]   : Chọn thanh ghi đích ghi kết quả (00: Không ghi, 01: rd, 10: rt, 11: $31 cho jal).
//    - alu_src    : Chọn toán hạng B của ALU (0: rt từ thanh ghi, 1: Hằng số Immediate mở rộng).
//    - ext[1:0]   : Chế độ mở rộng hằng số 16-bit (00: Sign-Extend, 01: Zero-Extend, 10: LUI lên 16 bit cao).
//    - alu_ctl[3:0]: Mã phép toán gửi cho khối ALU (ADD, SUB, AND, OR, XOR, SLT, SLL, SRA).
//    - res_sel[2:0]: Mux chọn nguồn dữ liệu ghi lại (0: ALU, 1: MUL, 2: HI, 3: LO, 4: BCD, 5: CP0, 6: PC+4).
//    - mem_read   : 1 = Kích hoạt đọc bộ nhớ dữ liệu (lệnh lw).
//    - mem_write  : 1 = Kích hoạt ghi bộ nhớ dữ liệu (lệnh sw).
//    - mem_to_reg : 1 = Dữ liệu ghi thanh ghi lấy từ bộ nhớ (lw).
//    - branch[1:0]: Điều khiển rẽ nhánh (01: beq, 10: bne).
//    - jump       : 1 = Nhảy tuyệt đối (j, jal).
//    - jump_reg   : 1 = Nhảy gián tiếp qua thanh ghi (jr).
//    - multi[1:0] : Báo hiệu lệnh nhiều chu kỳ (01: div 32 chu kỳ, 10: bcd tuần tự 27 chu kỳ).
//    - cp0_op[1:0]: Thao tác với Coprocessor 0 (01: mtc0, 10: eret).
//    - uses_rs/rt : Báo cho khối Hazard biết lệnh có thực sự sử dụng giá trị rs/rt hay không để tránh stall oan.
//    - valid      : 1 = Lệnh hợp lệ; 0 = Lệnh lạ (xử lý như NOP an toàn).
// ============================================================================

`timescale 1ns/1ps

module control #(
    parameter G_BCD_COMB = 0          // 1: Khối BCD tổ hợp (multi = 00); 0: Khối BCD tuần tự (multi = 10)
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire [31:0] instr,         // Từ lệnh 32-bit đọc từ bộ nhớ chương trình
    
    // Tín hiệu điều khiển tập thanh ghi
    output reg         reg_write,     // Cho phép ghi thanh ghi đích (RegWrite)
    output reg  [1:0]  dst,           // Chọn thanh ghi đích: 00=None, 01=rd, 10=rt, 11=$31
    
    // Tín hiệu điều khiển ALU và mở rộng toán hạng
    output reg         alu_src,       // Chọn toán hạng B của ALU: 0=rt, 1=Immediate
    output reg  [1:0]  ext,           // Chế độ mở rộng: 00=Sign-Extend, 01=Zero-Extend, 10=LUI
    output reg  [3:0]  alu_ctl,       // Mã phép tính số học/logic gửi ALU
    output reg  [2:0]  res_sel,       // Chọn kết quả ghi: 0=ALU, 1=MUL, 2=HI, 3=LO, 4=BCD, 5=CP0, 6=PC+4
    
    // Tín hiệu điều khiển bộ nhớ dữ liệu
    output reg         mem_read,      // Cho phép đọc bộ nhớ dữ liệu (MemRead - lệnh lw)
    output reg         mem_write,     // Cho phép ghi bộ nhớ dữ liệu (MemWrite - lệnh sw)
    output reg         mem_to_reg,    // Chọn dữ liệu ghi từ bộ nhớ (MemToReg)
    
    // Tín hiệu điều khiển rẽ nhánh và nhảy
    output reg  [1:0]  branch,        // Điều khiển rẽ nhánh: 01=beq, 10=bne
    output reg         jump,          // Nhảy không điều kiện (j, jal)
    output reg         jump_reg,      // Nhảy qua thanh ghi (jr)
    
    // Tín hiệu điều khiển ngoại vi đa chu kỳ & CP0
    output reg  [1:0]  multi,         // Lệnh đa chu kỳ: 01=div (32 nhịp), 10=bcd (27 nhịp)
    output reg  [1:0]  cp0_op,        // Lệnh CP0: 01=mtc0, 10=eret
    
    // Tín hiệu phân tích xung đột (Hazard Analysis)
    output reg         uses_rs,       // Lệnh có đọc thanh ghi rs thật sự
    output reg         uses_rt,       // Lệnh có đọc thanh ghi rt thật sự
    output reg         valid          // 1 = Lệnh hợp lệ thuộc tập 28 lệnh; 0 = Lệnh lạ
);

    // ------------------------------------------------------------------------
    // CÁC HẰNG SỐ MÃ HÓA TÍN HIỆU ĐIỀU KHIỂN (ENCODING CONSTANTS)
    // ------------------------------------------------------------------------
    localparam D_NONE = 2'b00, D_RD = 2'b01, D_RT = 2'b10, D_31 = 2'b11;
    localparam E_SE   = 2'b00, E_ZE = 2'b01, E_LUI = 2'b10;
    localparam A_ADD  = 4'd0,  A_SUB = 4'd1, A_AND = 4'd2, A_OR = 4'd3,
               A_XOR  = 4'd4,  A_SLT = 4'd5, A_SLL = 4'd6, A_SRA = 4'd7;
    localparam R_ALU  = 3'd0,  R_MUL = 3'd1, R_HI = 3'd2, R_LO = 3'd3,
               R_BCD  = 3'd4,  R_CP0 = 3'd5, R_PC4 = 3'd6;

    // Trích xuất các trường từ mã máy MIPS 32-bit
    wire [5:0] op    = instr[31:26];  // Mã thao tác chính (Opcode)
    wire [4:0] rs    = instr[25:21];  // Trường thanh ghi nguồn rs
    wire [5:0] funct = instr[5:0];    // Trường chức năng phụ (Function code)

    // ------------------------------------------------------------------------
    // CÁC TÁC VỤ MẪU GÁN TÍN HIỆU (HELPER TASKS)
    // ------------------------------------------------------------------------
    // Mẫu chuẩn cho các lệnh tính toán R-type (kết quả ghi vào rd)
    task r_alu(input [3:0] ctl, input u_rs);
        begin
            valid      = 1'b1;
            reg_write  = 1'b1;
            dst        = D_RD;
            alu_ctl    = ctl;
            res_sel    = R_ALU;
            uses_rs    = u_rs;
            uses_rt    = 1'b1;
        end
    endtask

    // Mẫu chuẩn cho các lệnh tính toán số học với hằng số I-type (kết quả ghi vào rt)
    task i_alu(input [3:0] ctl, input [1:0] e, input u_rs);
        begin
            valid      = 1'b1;
            reg_write  = 1'b1;
            dst        = D_RT;
            alu_src    = 1'b1;
            ext        = e;
            alu_ctl    = ctl;
            res_sel    = R_ALU;
            uses_rs    = u_rs;
        end
    endtask

    // ------------------------------------------------------------------------
    // BẢNG GIẢI MÃ TỔ HỢP 28 LỆNH MIPS (MAIN COMBINATIONAL DECODER)
    // ------------------------------------------------------------------------
    always @* begin
        // Khởi tạo toàn bộ tín hiệu điều khiển về trạng thái NOP an toàn
        valid      = 1'b0;
        reg_write  = 1'b0;
        dst        = D_NONE;
        alu_src    = 1'b0;
        ext        = E_SE;
        alu_ctl    = A_ADD;
        res_sel    = R_ALU;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        mem_to_reg = 1'b0;
        branch     = 2'b00;
        jump       = 1'b0;
        jump_reg   = 1'b0;
        multi      = 2'b00;
        cp0_op     = 2'b00;
        uses_rs    = 1'b0;
        uses_rt    = 1'b0;

        case (op)
            // ----------------------------------------------------------------
            // 1. NHÓM LỆNH R-TYPE (OPCODE = 0x00)
            // ----------------------------------------------------------------
            6'h00: begin
                case (funct)
                    6'h21: r_alu(A_ADD, 1);                             // addu: rd = rs + rt
                    6'h23: r_alu(A_SUB, 1);                             // subu: rd = rs - rt
                    6'h24: r_alu(A_AND, 1);                             // and : rd = rs & rt
                    6'h25: r_alu(A_OR,  1);                             // or  : rd = rs | rt
                    6'h26: r_alu(A_XOR, 1);                             // xor : rd = rs ^ rt
                    6'h2A: r_alu(A_SLT, 1);                             // slt : rd = (rs < rt) ? 1 : 0
                    6'h00: r_alu(A_SLL, 0);                             // sll : rd = rt << shamt (nop = sll $0,$0,0)
                    6'h03: r_alu(A_SRA, 0);                             // sra : rd = rt >>> shamt
                    6'h08: begin                                        // jr  : PC = rs
                        valid = 1'b1; jump_reg = 1'b1; uses_rs = 1'b1;
                    end
                    6'h1A: begin                                        // div : {HI, LO} = rs / rt
                        valid = 1'b1; multi = 2'b01; uses_rs = 1'b1; uses_rt = 1'b1;
                    end
                    6'h10: begin                                        // mfhi: rd = HI
                        valid = 1'b1; reg_write = 1'b1; dst = D_RD; res_sel = R_HI;
                    end
                    6'h12: begin                                        // mflo: rd = LO
                        valid = 1'b1; reg_write = 1'b1; dst = D_RD; res_sel = R_LO;
                    end
                    default: ;
                endcase
            end

            // ----------------------------------------------------------------
            // 2. NHÓM LỆNH I-TYPE VÀ BỘ NHỚ
            // ----------------------------------------------------------------
            6'h09: i_alu(A_ADD, E_SE,  1);                              // addiu: rt = rs + SignExt(imm)
            6'h0A: i_alu(A_SLT, E_SE,  1);                              // slti : rt = (rs < SignExt(imm)) ? 1 : 0
            6'h0C: i_alu(A_AND, E_ZE,  1);                              // andi : rt = rs & ZeroExt(imm)
            6'h0D: i_alu(A_OR,  E_ZE,  1);                              // ori  : rt = rs | ZeroExt(imm)
            6'h0F: i_alu(A_OR,  E_LUI, 0);                              // lui  : rt = {imm, 16'd0}
            
            6'h23: begin                                                // lw   : rt = Mem[rs + imm]
                i_alu(A_ADD, E_SE, 1);
                mem_read   = 1'b1;
                mem_to_reg = 1'b1;
            end
            
            6'h2B: begin                                                // sw   : Mem[rs + imm] = rt
                valid     = 1'b1;
                alu_src   = 1'b1;
                ext       = E_SE;
                alu_ctl   = A_ADD;
                mem_write = 1'b1;
                uses_rs   = 1'b1;
                uses_rt   = 1'b1;
            end

            // ----------------------------------------------------------------
            // 3. NHÓM LỆNH RẼ NHÁNH VÀ NHẢY
            // ----------------------------------------------------------------
            6'h04: begin                                                // beq  : if (rs == rt) branch
                valid = 1'b1; branch = 2'b01; uses_rs = 1'b1; uses_rt = 1'b1;
            end
            6'h05: begin                                                // bne  : if (rs != rt) branch
                valid = 1'b1; branch = 2'b10; uses_rs = 1'b1; uses_rt = 1'b1;
            end
            6'h02: begin                                                // j    : PC = JumpAddress
                valid = 1'b1; jump = 1'b1;
            end
            6'h03: begin                                                // jal  : $31 = PC + 4, PC = JumpAddress
                valid = 1'b1; jump = 1'b1; reg_write = 1'b1; dst = D_31; res_sel = R_PC4;
            end

            // ----------------------------------------------------------------
            // 4. NHÓM LỆNH MỞ RỘNG SPECIAL2 (OPCODE = 0x1C)
            // ----------------------------------------------------------------
            6'h1C: begin
                case (funct)
                    6'h02: begin                                        // mul  : rd = rs * rt
                        valid = 1'b1; reg_write = 1'b1; dst = D_RD; res_sel = R_MUL;
                        uses_rs = 1'b1; uses_rt = 1'b1;
                    end
                    6'h10: begin                                        // bcd  : rd = to_bcd(rs)
                        valid     = 1'b1;
                        reg_write = 1'b1;
                        dst       = D_RD;
                        res_sel   = R_BCD;
                        multi     = (G_BCD_COMB != 0) ? 2'b00 : 2'b10;
                        uses_rs   = 1'b1;
                    end
                    default: ;
                endcase
            end

            // ----------------------------------------------------------------
            // 5. NHÓM LỆNH ĐIỀU KHIỂN HỆ THỐNG COP0 (OPCODE = 0x10)
            // ----------------------------------------------------------------
            6'h10: begin
                if ((rs == 5'h00) && (instr[10:0] == 11'd0)) begin      // mfc0 : rt = CP0[rd]
                    valid = 1'b1; reg_write = 1'b1; dst = D_RT; res_sel = R_CP0;
                end else if ((rs == 5'h04) && (instr[10:0] == 11'd0)) begin // mtc0 : CP0[rd] = rt
                    valid = 1'b1; cp0_op = 2'b01; uses_rt = 1'b1;
                end else if (instr == 32'h42000018) begin               // eret : Return from exception
                    valid = 1'b1; cp0_op = 2'b10;
                end
            end

            default: ;
        endcase
    end

endmodule
