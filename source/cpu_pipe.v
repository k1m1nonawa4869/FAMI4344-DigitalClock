// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     cpu_pipe.v — Lõi Vi Xử Lý MIPS Đường Ống 5 Tầng (Pipelined MIPS Core)
// CHUYÊN ĐỀ KTMT: Chương 05: Kỹ Thuật Đường Ống 5 Tầng (5-Stage Pipelining) & Ngắt Chính Xác
// VAI TRÒ:        Lõi CPU Hiệu Năng Cao, Tối Đa Hóa Thông Lượng & Xử Lý Xung Đột (Pipelined CPU)
// MÔ TẢ:          Module thực thi 28 lệnh MIPS với kiến trúc đường ống 5 tầng kinh điển:
//                 - 5 tầng đường ống: IF (Lấy lệnh), ID (Giải mã/Đọc thanh ghi),
//                   EX (Thực thi ALU), MEM (Bộ nhớ), WB (Ghi kết quả).
//                 - Tích hợp khối Hazard Detection & Forwarding Unit giải quyết triệt để
//                   xung đột dữ liệu (RAW) và xung đột điều khiển (Branch).
//                 - Hỗ trợ cơ chế ngắt chính xác (Precise Exceptions) theo chuẩn MIPS.
//                 - Đạt thông lượng lý tưởng CPI tiến tới 1.0 ở tần số xung nhịp cao vượt trội so với G1.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Phân Tầng Đường Ống 5 Trạm (5-Stage Pipeline Architecture):
//    - Thay vì đợi một lệnh chạy trọn vẹn qua mọi công đoạn như CPU đơn chu kỳ (G1),
//      kiến trúc đường ống chia quá trình xử lý lệnh thành 5 trạm độc lập gối đầu nhau:
//        + Trạm 1 - IF  (Instruction Fetch)   : PC phát địa chỉ, BRAM chốt và nạp lệnh 32-bit vào thanh ghi IF/ID.
//        + Trạm 2 - ID  (Instruction Decode)  : Khối control giải mã vi lệnh, đọc 2 toán hạng từ RegFile (có bypass).
//        + Trạm 3 - EX  (Execute / ALU)       : Khối ALU/muldiv/bcd tính toán, mạch Forwarding cấp dữ liệu, giải quyết rẽ nhánh.
//        + Trạm 4 - MEM (Memory Access)       : Truy xuất đọc/ghi DMEM hoặc gửi yêu cầu lên Bus MMIO ngoại vi.
//        + Trạm 5 - WB  (Write Back)          : Ghi kết quả cuối cùng từ ALU hoặc Bộ nhớ về tập thanh ghi RegFile.
//    - Nhờ chia nhỏ đường truyền, chu kỳ clock chỉ bị giới hạn bởi trạm trễ nhất:
//          T_clk >= max(T_IF, T_ID, T_EX, T_MEM, T_WB)  ==> Tần số f_clk tăng gấp ~3 đến 4 lần so với G1.
//
// 2. Các Thanh Ghi Trung Gian Liên Tầng (Pipeline Registers):
//    - Dữ liệu và các tín hiệu điều khiển được truyền đồng bộ qua 4 thanh ghi liên tầng:
//        + `ifid_` : Chốt kết quả giữa tầng IF và ID (PC, từ lệnh instr).
//        + `idex_` : Chốt kết quả giữa tầng ID và EX (các vi lệnh, toán hạng opA, opB, immediate mở rộng, rd/rt).
//        + `exm_`  : Chốt kết quả giữa tầng EX và MEM (kết quả ALU/địa chỉ bộ nhớ, dữ liệu ghi store data).
//        + `mw_`   : Chốt kết quả giữa tầng MEM và WB (dữ liệu đọc load data, kết quả ALU, thanh ghi đích).
//
// 3. Giải Quyết Xung Đột Đường Ống (Hazard Resolution):
//    - Data Forwarding (Chuyển tiếp dữ liệu): Kết quả vừa tính ở đầu ra EX/MEM hoặc MEM/WB được nối tắt
//      thẳng vào đầu vào ALU của tầng EX, loại bỏ phần lớn độ trễ chờ đợi thanh ghi.
//    - Load-Use Hazard: Lệnh `lw` đi liền trước lệnh cần dữ liệu bắt buộc phải chèn 1 chu kỳ dừng (`stall_lu = 1`),
//      giữ nguyên IF/ID và PC, chèn 1 bong bóng NOP vào ID/EX.
//    - Multi-cycle Stall (`stall_busy`): Lệnh chia `div` hoặc `bcd` tuần tự giữ trạm EX bận nhiều chu kỳ,
//      các trạm phía sau tiếp tục trôi đi và nhận bong bóng cho tới khi phép tính xong.
//    - Branch Penalty Flush: Quyết định rẽ nhánh/nhảy được chốt tại tầng EX; nếu nhánh được thực hiện (`taken = 1`),
//      hai lệnh đã nạp sai ở IF/ID và ID/EX bị xóa sạch (Flush) thành lệnh rỗng NOP.
//
// 4. Cơ Chế Ngắt Chính Xác (Precise Interrupt Mechanism):
//    - Khi có yêu cầu ngắt ngoại vi hợp lệ:
//        + Lệnh đã tới tầng EX/MEM và MEM/WB tiếp tục được phép chạy trọn vẹn và retire an toàn.
//        + Lệnh đang ở tầng ID/EX bị hủy bỏ.
//        + Thanh ghi EPC chốt địa chỉ của lệnh cũ nhất chưa hoàn tất (`irq_epc = idex_v ? idex_pc : ...`).
//        + PC được nạp địa chỉ xử lý ngắt cố định 32'h0000_0180.
//      Sau khi kết thúc ngắt bằng lệnh `eret`, CPU quay trở lại đúng vị trí lệnh bị dừng mà không sót lệnh.
// ============================================================================

`timescale 1ns/1ps

module cpu_pipe #(
    parameter IMEM_FILE  = "",          // Tệp hex nạp vào bộ nhớ lệnh IMEM
    parameter DMEM_FILE  = "",          // Tệp hex nạp vào bộ nhớ dữ liệu DMEM
    parameter G_IMEM_AW  = 10,          // Độ rộng địa chỉ IMEM: 2^10 = 1024 lệnh (4 KB)
    parameter G_BCD_COMB = 0,           // 1: BCD tổ hợp; 0: BCD tuần tự 27 chu kỳ
    parameter TRACE_FILE = ""           // Tệp ghi vết thực thi mô phỏng
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,             // Xung nhịp hệ thống 50 MHz
    input  wire        rst,             // Reset đồng bộ mức cao (Active-high Reset)
    input  wire        cpu_ce,          // Clock Enable của CPU (G2: cpu_ce = 1 mọi chu kỳ)
    
    // Giao diện Bus MMIO kết nối ngoại vi SoC
    output wire [7:0]  bus_addr,        // Địa chỉ byte offset trong không gian ngoại vi
    output wire [31:0] bus_wdata,       // Dữ liệu ghi ra ngoại vi MMIO
    output wire        bus_we,          // Tín hiệu ghi MMIO
    output wire        bus_re,          // Tín hiệu đọc MMIO
    input  wire [31:0] bus_rdata,       // Dữ liệu đọc từ ngoại vi MMIO trả về CPU
    
    // Tín hiệu ngắt và giám sát
    input  wire        irq,             // Mức tích cực ngắt tổng hợp từ irq_ctrl
    input  wire [7:0]  irq_ip,          // Các nguồn ngắt đang chờ (Cause.IP)
    output wire        div_dz,          // Cờ báo chia cho 0 từ bộ chia muldiv
    output wire [31:0] pc_out,          // Địa chỉ PC hiện tại xuất ra ngoài giám sát
    output wire        retire           // Xung 1 chu kỳ: Lệnh hợp lệ rời tầng WB (hoàn tất)
);

    localparam NI = 1 << G_IMEM_AW;

    // ------------------------------------------------------------------------
    // BỘ NHỚ VÀ TRẠNG THÁI HỆ THỐNG (MEMORY & ARCHITECTURAL STATE)
    // ------------------------------------------------------------------------
    reg  [31:0] imem [0:NI-1];          // Bộ nhớ lệnh IMEM
    reg  [31:0] dmem [0:1023];          // Bộ nhớ dữ liệu DMEM 4 KB
    reg  [31:0] pc;                     // Bộ đếm chương trình (tại tầng IF)
    reg  [1:0]  status;                 // Thanh ghi trạng thái CP0: [1] EXL, [0] IE
    reg  [31:0] epc;                    // Thanh ghi lưu địa chỉ trở về ngắt EPC
    reg         started;                // Cờ đánh dấu lệnh đa chu kỳ đã nhận start

    // ------------------------------------------------------------------------
    // THANH GHI LIÊN TẦNG 1: IF/ID (INSTRUCTION FETCH -> DECODE)
    // ------------------------------------------------------------------------
    reg         ifid_v;                 // Cờ báo lệnh hợp lệ (1 = lệnh thật, 0 = bong bóng NOP)
    reg  [31:0] ifid_pc, ifid_ins;

    // ------------------------------------------------------------------------
    // THANH GHI LIÊN TẦNG 2: ID/EX (DECODE -> EXECUTE)
    // ------------------------------------------------------------------------
    reg         idex_v, idex_rw, idex_m2r, idex_mrd, idex_mwr, idex_asrc, idex_jmp, idex_jr;
    reg  [3:0]  idex_actl;
    reg  [2:0]  idex_rsel;
    reg  [1:0]  idex_br, idex_multi, idex_cp0;
    reg  [31:0] idex_pc, idex_pc4, idex_ins, idex_a, idex_b, idex_imm;
    reg  [4:0]  idex_sh, idex_rd, idex_rs, idex_rt, idex_dst;
    reg  [25:0] idex_j;

    // ------------------------------------------------------------------------
    // THANH GHI LIÊN TẦNG 3: EX/MEM (EXECUTE -> MEMORY)
    // ------------------------------------------------------------------------
    reg         exm_v, exm_rw, exm_m2r, exm_mrd, exm_mwr;
    reg  [31:0] exm_res, exm_st, exm_pc, exm_ins;
    reg  [4:0]  exm_dst;
    reg  [1:0]  exm_cp0;

    // ------------------------------------------------------------------------
    // THANH GHI LIÊN TẦNG 4: MEM/WB (MEMORY -> WRITE BACK)
    // ------------------------------------------------------------------------
    reg         mw_v, mw_rw, mw_m2r, mw_mrd, mw_mwr, mw_lmmio;
    reg  [31:0] mw_res, mw_mdata, mw_st, mw_addr, mw_pc, mw_ins;
    reg  [4:0]  mw_dst;
    reg  [1:0]  mw_cp0;

    // ------------------------------------------------------------------------
    // TẦNG 2: GIẢI MÃ LỆNH & TẬP THANH GHI (ID STAGE)
    // ------------------------------------------------------------------------
    wire [4:0]  f_rs  = ifid_ins[25:21], 
                f_rt  = ifid_ins[20:16], 
                f_rd  = ifid_ins[15:11], 
                f_sh  = ifid_ins[10:6];
    wire [15:0] imm16 = ifid_ins[15:0];

    wire       reg_write, alu_src, mem_read, mem_write, mem_to_reg, jump, jump_reg, uses_rs, uses_rt, valid;
    wire [1:0] dst_sel, d_ext, branch, multi, cp0_op;
    wire [3:0] alu_ctl;
    wire [2:0] res_sel;

    control #(.G_BCD_COMB(G_BCD_COMB)) u_ctl (
        .instr(ifid_ins),
        .reg_write(reg_write),
        .dst(dst_sel),
        .alu_src(alu_src),
        .ext(d_ext),
        .alu_ctl(alu_ctl),
        .res_sel(res_sel),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .branch(branch),
        .jump(jump),
        .jump_reg(jump_reg),
        .multi(multi),
        .cp0_op(cp0_op),
        .uses_rs(uses_rs),
        .uses_rt(uses_rt),
        .valid(valid)
    );

    wire [31:0] imm_x = (d_ext == 2'b01) ? {16'd0, imm16} :
                        (d_ext == 2'b10) ? {imm16, 16'd0} : {{16{imm16[15]}}, imm16};

    wire [4:0] d_dst = (!ifid_v)          ? 5'd0 :
                       (dst_sel == 2'b01) ? f_rd :
                       (dst_sel == 2'b10) ? f_rt :
                       (dst_sel == 2'b11) ? 5'd31 : 5'd0;

    wire [31:0] rs_v, rt_v, wb;
    wire        we_rf = cpu_ce && mw_v && mw_rw; // Ghi kết quả ở tầng WB
    
    regfile #(.G_BYPASS(1)) u_rf (
        .clk(clk),
        .rst(rst),
        .we(we_rf),
        .wa(mw_dst),
        .wd(wb),
        .ra1(f_rs),
        .ra2(f_rt),
        .rd1(rs_v),
        .rd2(rt_v)
    );

    // ------------------------------------------------------------------------
    // KHỐI XỬ LÝ XUNG ĐỘT ĐƯỜNG ỐNG (HAZARD UNIT INSTANCE)
    // ------------------------------------------------------------------------
    wire        stall_lu, flush;
    wire [1:0]  fwd_a, fwd_b;
    wire        stall_busy;
    wire        take;
    wire        take_irq;
    reg         irq_tr;
    reg         last_cp0;
    wire [31:0] irq_epc = idex_v ? idex_pc : ifid_v ? ifid_pc : pc;

    hazard u_haz (
        .ifid_valid(ifid_v),
        .ifid_rs(f_rs),
        .ifid_rt(f_rt),
        .ifid_uses_rs(uses_rs),
        .ifid_uses_rt(uses_rt),
        .idex_mem_read(idex_mrd),
        .idex_dst(idex_dst),
        .idex_rs(idex_rs),
        .idex_rt(idex_rt),
        .exmem_reg_write(exm_rw),
        .exmem_dst(exm_dst),
        .memwb_reg_write(mw_rw),
        .memwb_dst(mw_dst),
        .taken(take),
        .stall_lu(stall_lu),
        .flush(flush),
        .fwd_a(fwd_a),
        .fwd_b(fwd_b)
    );

    // ------------------------------------------------------------------------
    // TẦNG 3: THỰC THI SỐ HỌC & RẼ NHÁNH (EX STAGE)
    // ------------------------------------------------------------------------
    // Lựa chọn nguồn toán hạng sau mạch Forwarding
    wire [31:0] opA   = (fwd_a == 2'b10) ? exm_res : (fwd_a == 2'b01) ? wb : idex_a;
    wire [31:0] opB   = (fwd_b == 2'b10) ? exm_res : (fwd_b == 2'b01) ? wb : idex_b;
    wire [31:0] alu_b = idex_asrc ? idex_imm : opB;
    wire [31:0] alu_y;
    wire        alu_zero;
    
    alu u_alu (
        .a(opA),
        .b(alu_b),
        .shamt(idex_sh),
        .ctl(idex_actl),
        .y(alu_y),
        .zero(alu_zero)
    );

    wire [31:0] mul_y, lo, hi, bcd_y;
    wire        md_busy, md_done, bc_busy, bc_done;
    wire        md_go = cpu_ce && (idex_multi == 2'b01) && !started;
    wire        bc_go = cpu_ce && (idex_multi == 2'b10) && !started;

    muldiv u_md (
        .clk(clk),
        .rst(rst),
        .ce(cpu_ce),
        .start(md_go),
        .a(opA),
        .b(opB),
        .mul_y(mul_y),
        .busy(md_busy),
        .done(md_done),
        .lo(lo),
        .hi(hi),
        .dz(div_dz)
    );

    bcd_unit #(.G_COMB(G_BCD_COMB)) u_bcd (
        .clk(clk),
        .rst(rst),
        .ce(cpu_ce),
        .start(bc_go),
        .x(opA),
        .busy(bc_busy),
        .done(bc_done),
        .y(bcd_y)
    );

    wire mdone = (idex_multi == 2'b01) ? md_done : 
                 (idex_multi == 2'b10) ? bc_done : 1'b1;
    assign stall_busy = (idex_multi != 2'b00) && !mdone;

    reg [31:0] cp0_rd;
    always @* begin
        case (idex_rd)
            5'd12:   cp0_rd = {30'd0, status};
            5'd13:   cp0_rd = {16'd0, irq_ip, 8'd0};
            5'd14:   cp0_rd = epc;
            default: cp0_rd = 32'd0;
        endcase
    end

    reg [31:0] ex_res;
    always @* begin
        case (idex_rsel)
            3'd1:    ex_res = mul_y;
            3'd2:    ex_res = hi;
            3'd3:    ex_res = lo;
            3'd4:    ex_res = bcd_y;
            3'd5:    ex_res = cp0_rd;
            3'd6:    ex_res = idex_pc4;
            default: ex_res = alu_y;
        endcase
    end

    // Quyết định rẽ nhánh hoặc nhảy tại tầng EX
    wire eq   = (opA == opB);
    assign take = idex_v && !stall_busy &&
                  ((idex_br == 2'b01 && eq) || 
                   (idex_br == 2'b10 && !eq) || 
                   idex_jmp || idex_jr || (idex_cp0 == 2'b10));

    wire [31:0] tgt = (idex_cp0 == 2'b10) ? epc :
                      idex_jr             ? {opA[31:2], 2'b00} :
                      idex_jmp            ? {idex_pc4[31:28], idex_j, 2'b00} :
                                            idex_pc4 + {idex_imm[29:0], 2'b00};

    // ------------------------------------------------------------------------
    // TẦNG 4: TRUY XUẤT BỘ NHỚ (MEM STAGE)
    // ------------------------------------------------------------------------
    wire in_dmem = (exm_res[31:12] == 20'd0);
    wire in_mmio = (exm_res[31:8] == 24'hFFFFFF);
    
    assign bus_addr  = {exm_res[7:2], 2'b00};
    assign bus_wdata = exm_st;
    assign bus_we    = cpu_ce && exm_v && exm_mwr && in_mmio;
    assign bus_re    = cpu_ce && exm_v && exm_mrd && in_mmio;

    // ------------------------------------------------------------------------
    // TẦNG 5: GHI KẾT QUẢ VỀ THANH GHI (WB STAGE)
    // ------------------------------------------------------------------------
    wire [31:0] wb_ld = mw_lmmio ? bus_rdata : mw_mdata;
    assign wb = mw_m2r ? wb_ld : mw_res;

    assign pc_out = pc;
    assign retire = cpu_ce && mw_v;

    // Điều kiện tiếp nhận ngắt chính xác tại tầng ID/EX
    assign take_irq = cpu_ce && irq && status[0] && !status[1] && !stall_busy && !stall_lu
                      && !(idex_v && idex_cp0 != 2'b00) && (idex_multi == 2'b00)
                      && !(exm_v ? (exm_cp0 != 2'b00) : mw_v ? (mw_cp0 != 2'b00) : last_cp0);
    
    wire id_ok = ifid_v && !take && !stall_lu && !take_irq;

    // ------------------------------------------------------------------------
    // KHỞI TẠO BỘ NHỚ & TIẾN TRÌNH DỊCH CHUYỂN ĐƯỜNG ỐNG
    // ------------------------------------------------------------------------
`ifndef SYNTHESIS
    integer j;
    initial begin
        for (j = 0; j < NI; j = j + 1) imem[j] = 32'd0;
        for (j = 0; j < 1024; j = j + 1) dmem[j] = 32'd0;
    end
`endif

    generate
        if (IMEM_FILE != "") begin : g_imem_init
            initial $readmemh(IMEM_FILE, imem);
        end
        if (DMEM_FILE != "") begin : g_dmem_init
            initial $readmemh(DMEM_FILE, dmem);
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            pc        <= 32'd0;
            status    <= 2'b00;
            epc       <= 32'd0;
            started   <= 1'b0;
            ifid_v    <= 1'b0;  ifid_pc   <= 32'd0;  ifid_ins  <= 32'd0;
            idex_v    <= 1'b0;  idex_rw   <= 1'b0;   idex_m2r  <= 1'b0;
            idex_mrd  <= 1'b0;  idex_mwr  <= 1'b0;   idex_asrc <= 1'b0;
            idex_jmp  <= 1'b0;  idex_jr   <= 1'b0;   idex_actl <= 4'd0;
            idex_rsel <= 3'd0;  idex_br   <= 2'd0;   idex_multi<= 2'd0;
            idex_cp0  <= 2'd0;  idex_dst  <= 5'd0;   idex_rs   <= 5'd0;
            idex_rt   <= 5'd0;  idex_rd   <= 5'd0;   idex_sh   <= 5'd0;
            idex_j    <= 26'd0; idex_pc   <= 32'd0;  idex_pc4  <= 32'd0;
            idex_ins  <= 32'd0; idex_a    <= 32'd0;  idex_b    <= 32'd0;
            idex_imm  <= 32'd0;
            exm_v     <= 1'b0;  exm_rw    <= 1'b0;   exm_m2r   <= 1'b0;
            exm_mrd   <= 1'b0;  exm_mwr   <= 1'b0;   exm_dst   <= 5'd0;
            exm_res   <= 32'd0; exm_st    <= 32'd0;  exm_pc    <= 32'd0;
            exm_ins   <= 32'd0; exm_cp0   <= 2'd0;
            mw_v      <= 1'b0;  mw_rw     <= 1'b0;   mw_m2r    <= 1'b0;
            mw_mrd    <= 1'b0;  mw_mwr    <= 1'b0;   mw_lmmio  <= 1'b0;
            mw_dst    <= 5'd0;  mw_res    <= 32'd0;  mw_mdata  <= 32'd0;
            mw_st     <= 32'd0; mw_addr   <= 32'd0;  mw_pc     <= 32'd0;
            mw_ins    <= 32'd0; mw_cp0    <= 2'd0;
            irq_tr    <= 1'b0;  last_cp0  <= 1'b0;
        end else if (cpu_ce) begin
            irq_tr <= take_irq;
            if (mw_v) last_cp0 <= (mw_cp0 != 2'b00);

            // Ghi bộ nhớ dữ liệu DMEM tại tầng MEM
            if (exm_v && exm_mwr && in_dmem) dmem[exm_res[11:2]] <= exm_st;

            // Xử lý ghi CP0 tại tầng EX
            if (idex_v && !stall_busy) begin
                if (idex_cp0 == 2'b01) begin // mtc0
                    if (idex_rd == 5'd12) status <= opB[1:0];
                    if (idex_rd == 5'd14) epc    <= {opB[31:2], 2'b00};
                end
                if (idex_cp0 == 2'b10) status[1] <= 1'b0; // eret: xóa cờ EXL
            end

            // Tiếp nhận ngắt chính xác: chốt EPC và nhảy vector 0x180
            if (take_irq) begin
                epc       <= irq_epc;
                status[1] <= 1'b1;
            end
            started <= (idex_multi != 2'b00) && !mdone;

            // Dịch chuyển tầng: MEM/WB <= EX/MEM
            mw_v     <= exm_v;
            mw_rw    <= exm_rw;
            mw_m2r   <= exm_m2r;
            mw_mrd   <= exm_mrd;
            mw_mwr   <= exm_mwr;
            mw_lmmio <= exm_mrd && in_mmio;
            mw_dst   <= exm_dst;
            mw_res   <= exm_res;
            mw_st    <= exm_st;
            mw_addr  <= exm_res;
            mw_pc    <= exm_pc;
            mw_ins   <= exm_ins;
            mw_cp0   <= exm_cp0;
            mw_mdata <= in_dmem ? dmem[exm_res[11:2]] : 32'd0;

            // Dịch chuyển tầng: EX/MEM <= EX (chèn bong bóng khi EX bận)
            if (stall_busy) begin
                exm_cp0 <= 2'd0;
                exm_v   <= 1'b0;
                exm_rw  <= 1'b0;
                exm_m2r <= 1'b0;
                exm_mrd <= 1'b0;
                exm_mwr <= 1'b0;
                exm_dst <= 5'd0;
            end else begin
                exm_cp0 <= idex_cp0;
                exm_v   <= idex_v && !take_irq;
                exm_rw  <= idex_rw;
                exm_m2r <= idex_m2r;
                exm_mrd <= idex_mrd;
                exm_mwr <= idex_mwr;
                exm_dst <= idex_dst;
                exm_res <= ex_res;
                exm_st  <= opB;
                exm_pc  <= idex_pc;
                exm_ins <= idex_ins;
            end

            if (!stall_busy) begin
                // Dịch chuyển tầng: ID/EX <= ID (chèn bong bóng khi rẽ nhánh, load-use)
                idex_v     <= id_ok;
                idex_rw    <= id_ok && reg_write;
                idex_m2r   <= id_ok && mem_to_reg;
                idex_mrd   <= id_ok && mem_read;
                idex_mwr   <= id_ok && mem_write;
                idex_asrc  <= id_ok && alu_src;
                idex_actl  <= id_ok ? alu_ctl : 4'd0;
                idex_rsel  <= id_ok ? res_sel : 3'd0;
                idex_br    <= id_ok ? branch : 2'd0;
                idex_jmp   <= id_ok && jump;
                idex_jr    <= id_ok && jump_reg;
                idex_multi <= id_ok ? multi : 2'd0;
                idex_cp0   <= id_ok ? cp0_op : 2'd0;
                idex_dst   <= id_ok ? d_dst : 5'd0;
                idex_pc    <= ifid_pc;
                idex_pc4   <= ifid_pc + 32'd4;
                idex_ins   <= ifid_ins;
                idex_a     <= rs_v;
                idex_b     <= rt_v;
                idex_imm   <= imm_x;
                idex_sh    <= f_sh;
                idex_rs    <= f_rs;
                idex_rt    <= f_rt;
                idex_rd    <= f_rd;
                idex_j     <= ifid_ins[25:0];

                // Cập nhật tầng IF/ID và PC (giữ nguyên khi load-use stall)
                if (!stall_lu) begin
                    pc       <= take_irq ? 32'h0000_0180 : take ? tgt : pc + 32'd4;
                    ifid_v   <= !take && !take_irq;
                    ifid_pc  <= pc;
                    ifid_ins <= imem[pc[G_IMEM_AW+1:2]];
                end
            end
        end
    end

    wire unused_ok = &{1'b0, alu_zero, md_busy, bc_busy, flush, mw_addr[1:0]};

`ifndef SYNTHESIS
    integer tf, cyc, n_ret;
    reg [31:0] tr_end;
    initial begin
        tf = 0; cyc = 0; n_ret = 0; tr_end = 32'hFFFF_FFFF;
        if (TRACE_FILE != "") tf = $fopen(TRACE_FILE, "w");
    end
    always @(posedge clk) begin
        if (rst) cyc <= 0; else cyc <= cyc + 1;
        if (!rst && cpu_ce && idex_v && !stall_busy && exm_v && exm_mrd &&
            ((fwd_a == 2'b10) || (fwd_b == 2'b10)))
            $display("ASSERT forward tu EX/MEM khi load: pc=%h", idex_pc);
        if (!rst && cpu_ce && ifid_v && !valid)
            $display("ASSERT lenh la: pc=%h instr=%h", ifid_pc, ifid_ins);
        if (!rst && retire && mw_pc < tr_end) begin
            n_ret <= n_ret + 1;
            if (tf != 0)
                $fwrite(tf, "%0d,%h,%h,%0d,%h,%s,%h,%h\n", cyc, mw_pc, mw_ins,
                        (mw_rw && mw_dst != 0) ? mw_dst : 5'd0,
                        (mw_rw && mw_dst != 0) ? wb : 32'd0,
                        mw_mrd ? "R" : mw_mwr ? "W" : "-",
                        (mw_mrd || mw_mwr) ? {mw_addr[31:2], 2'b00} : 32'd0,
                        mw_mrd ? wb_ld : mw_mwr ? mw_st : 32'd0);
        end
        if (tf != 0 && cpu_ce && irq_tr)
            $fwrite(tf, "%0d,00000180,INTERRUPT,0,00000000,-,00000000,00000000\n", cyc);
    end
`endif

endmodule
