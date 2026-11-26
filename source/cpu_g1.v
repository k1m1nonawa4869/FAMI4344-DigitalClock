// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     cpu_g1.v — Lõi Vi Xử Lý MIPS Đơn Chu Kỳ (Single-Cycle MIPS Core)
// CHUYÊN ĐỀ KTMT: Chương 04: Bộ Xử Lý Trung Tâm MIPS, Đường Dữ Liệu & Khối Điều Khiển
// VAI TRÒ:        Lõi Xử Lý Đơn Chu Kỳ 28 Lệnh & Giao Tiếp BRAM 2 Pha (Single-Cycle CPU)
// MÔ TẢ:          Module thực thi 28 lệnh MIPS cốt lõi với kiến trúc đơn chu kỳ:
//                 - Thực thi mỗi lệnh trong 1 chu kỳ CPU hoàn chỉnh (CPI = 1).
//                 - Khắc phục trễ đọc 1 nhịp của bộ nhớ BRAM FPGA bằng cơ chế vi bước 2 pha:
//                   + Pha B: Truy xuất bộ nhớ dữ liệu DMEM / Bus MMIO.
//                   + Pha A: Cập nhật PC, RegFile, HI/LO, CP0 và nạp lệnh mới từ IMEM.
//                 - Hỗ trợ dừng (Stall) khi thực thi các lệnh đa chu kỳ (div 32 nhịp, bcd 27 nhịp).
//                 - Hỗ trợ cơ chế ngắt chính xác Coprocessor 0 (Status, Cause, EPC) nhảy tới 0x180.
// ============================================================================
//
// ----------------------------------------------------------------------------
// CƠ SỞ LÝ THUYẾT & NGUYÊN LÝ THIẾT KẾ (THEORETICAL FOUNDATION)
// ----------------------------------------------------------------------------
// 1. Kiến trúc Đường Dữ Liệu Đơn Chu Kỳ (Single-Cycle Datapath):
//    - Mỗi lệnh MIPS được nạp, giải mã, thực thi, truy xuất bộ nhớ và ghi kết quả
//      hoàn tất trong một chu kỳ CPU (CPI = 1).
//    - Đường truyền trễ dài nhất (Critical Path) quyết định chu kỳ xung nhịp:
//          T_clk >= T_IMEM + T_RegRead + T_ALU + T_DMEM + T_RegSetup.
//    - Đây là kiến trúc chuẩn mực được giảng dạy trong học phần Kiến trúc Máy tính
//      để đối sánh hiệu năng (Design Space Exploration - DSE) với kiến trúc đường ống 5 tầng (G2).
//
// 2. Cơ chế Vi Bước 2 Pha Thích Ứng Bộ Nhớ Khối FPGA (2-Phase BRAM Timing):
//    - Trong phần cứng FPGA hiện đại, các khối bộ nhớ BRAM (Block RAM) bắt buộc phải có
//      thanh ghi chốt địa chỉ đầu vào và trả dữ liệu ra sau 1 cạnh xung nhịp (Synchronous Read).
//    - Để giữ nguyên ngữ nghĩa "đơn chu kỳ" mà vẫn tương thích với BRAM, mỗi chu kỳ CPU được chia
//      làm 2 nhịp cpu_ce (Pha B trước, Pha A sau):
//        + Pha B (ph_b): ALU đã tính xong địa chỉ; chốt địa chỉ vào DMEM/MMIO. Lệnh `sw` ghi dữ liệu,
//          lệnh `lw` bắt đầu đọc ra thanh ghi đầu ra của RAM.
//        + Pha A (ph_a): Dữ liệu đọc từ DMEM đã sẵn sàng. Ghi kết quả vào RegFile, cập nhật PC mới,
//          chốt địa chỉ PC mới vào IMEM để lấy lệnh cho chu kỳ tiếp theo.
//
// 3. Xử Lý Các Lệnh Đa Chu Kỳ (Multi-Cycle Execution in Single-Cycle Datapath):
//    - Lệnh chia `div` (32 chu kỳ) và lệnh đổi cơ số `bcd` tuần tự (27 chu kỳ) cần nhiều nhịp clock.
//    - Tín hiệu `stall = (multi != 2'b00) && !mdone` kích hoạt giữ nguyên PC và ngăn cản cập nhật
//      RegFile cho tới khi khối chức năng tương ứng phát tín hiệu hoàn thành `done`.
//
// 4. Cơ chế Ngắt Ngoại Vi Coprocessor 0 (CP0 Interrupt Handling):
//    - Điều kiện tiếp nhận ngắt: Tín hiệu `irq = 1`, cờ cho phép ngắt toàn cục `IE = status[0] = 1`,
//      không nằm trong ngắt lồng nhau `EXL = status[1] = 0`, CPU không bị stall và lệnh hiện tại
//      không phải lệnh thay đổi trạng thái CP0 (`mtc0`, `eret`).
//    - Khi tiếp nhận ngắt:
//        + EPC <= next_pc (Lưu địa chỉ lệnh kế tiếp cần thực thi sau khi xong ngắt).
//        + PC <= 32'h0000_0180 (Vector ngắt phần cứng tiêu chuẩn của MIPS).
//        + status[1] <= 1'b1 (Bật cờ EXL - Exception Level để tự động khóa ngắt lồng).
// ============================================================================

`timescale 1ns/1ps

module cpu_g1 #(
    parameter IMEM_FILE  = "",          // Tệp hex nạp sẵn vào bộ nhớ lệnh IMEM
    parameter DMEM_FILE  = "",          // Tệp hex nạp sẵn vào bộ nhớ dữ liệu DMEM
    parameter G_IMEM_AW  = 10,          // Độ rộng địa chỉ IMEM: 2^10 = 1024 lệnh (4 KB)
    parameter G_BCD_COMB = 0,           // 1: BCD tổ hợp; 0: BCD tuần tự 27 chu kỳ
    parameter TRACE_FILE = ""           // Tệp ghi vết thực thi (chỉ dùng trong mô phỏng)
) (
    // ------------------------------------------------------------------------
    // CÁC CỔNG GIAO TIẾP (PORTS & INTERFACES)
    // ------------------------------------------------------------------------
    input  wire        clk,             // Xung nhịp hệ thống 50 MHz
    input  wire        rst,             // Reset đồng bộ mức cao (Active-high Reset)
    input  wire        cpu_ce,          // Clock Enable của CPU (G1: cpu_ce = 1 mọi chu kỳ)
    
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
    output wire        retire           // Xung 1 chu kỳ: Lệnh hiện tại hoàn tất tại cạnh này
);

    localparam NI = 1 << G_IMEM_AW;

    // ------------------------------------------------------------------------
    // THANH GHI VÀ TRẠNG THÁI CPU (ARCHITECTURAL REGISTERS)
    // ------------------------------------------------------------------------
    reg  [31:0] pc;                     // Bộ đếm chương trình (Program Counter)
    reg  [31:0] instr;                  // Thanh ghi lưu lệnh đang thực thi (đầu ra IMEM)
    reg         phb;                    // Cờ báo pha: 1 = Cạnh tiếp theo là Pha B, 0 = Pha A
    reg  [31:0] imem [0:NI-1];          // Bộ nhớ lệnh IMEM
    reg  [31:0] dmem [0:1023];          // Bộ nhớ dữ liệu DMEM 4 KB (1024 word)
    reg  [31:0] dmem_q;                 // Dữ liệu đọc ra từ DMEM
    reg  [1:0]  lsel;                   // Chọn nguồn đọc: 01=DMEM, 10=MMIO, 00=Không gì (trả về 0)
    reg         started;                // Cờ đánh dấu lệnh đa chu kỳ đã nhận start
    reg  [1:0]  status;                 // Thanh ghi trạng thái CP0: [1] EXL, [0] IE
    reg  [31:0] epc;                    // Thanh ghi lưu địa chỉ trở về ngắt EPC (CP0 thanh ghi 14)

    wire ph_a = cpu_ce && !phb;
    wire ph_b = cpu_ce &&  phb;

    // ------------------------------------------------------------------------
    // KHỐI ĐIỀU KHIỂN & GIẢI MÃ LỆNH (CONTROL UNIT INSTANCE)
    // ------------------------------------------------------------------------
    wire       reg_write, alu_src, mem_read, mem_write, mem_to_reg, jump, jump_reg, uses_rs, uses_rt, valid;
    wire [1:0] dst, ext, branch, multi, cp0_op;
    wire [3:0] alu_ctl;
    wire [2:0] res_sel;
    
    control #(.G_BCD_COMB(G_BCD_COMB)) u_ctl (
        .instr(instr),
        .reg_write(reg_write),
        .dst(dst),
        .alu_src(alu_src),
        .ext(ext),
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

    // Trích xuất các trường từ lệnh
    wire [4:0]  f_rs = instr[25:21], 
                f_rt = instr[20:16], 
                f_rd = instr[15:11], 
                f_sh = instr[10:6];
    wire [15:0] imm  = instr[15:0];
    
    // Mở rộng hằng số Immediate 16-bit
    wire [31:0] imm_x = (ext == 2'b01) ? {16'd0, imm} :
                        (ext == 2'b10) ? {imm, 16'd0} : {{16{imm[15]}}, imm};

    // ------------------------------------------------------------------------
    // TẬP THANH GHI ĐA NĂNG (REGISTER FILE INSTANCE)
    // ------------------------------------------------------------------------
    // G1 không dùng bypass: Ghi tại Pha A ở cạnh sườn lên xung nhịp
    wire [31:0] rs_v, rt_v, wb;
    wire [4:0]  wa = (dst == 2'b01) ? f_rd : 
                     (dst == 2'b10) ? f_rt : 
                     (dst == 2'b11) ? 5'd31 : 5'd0;
    wire        stall;
    wire        rf_we = ph_a && reg_write && !stall;
    
    regfile #(.G_BYPASS(0)) u_rf (
        .clk(clk),
        .rst(rst),
        .we(rf_we),
        .wa(wa),
        .wd(wb),
        .ra1(f_rs),
        .ra2(f_rt),
        .rd1(rs_v),
        .rd2(rt_v)
    );

    // ------------------------------------------------------------------------
    // KHỐI TÍNH TOÁN SỐ HỌC (ALU, MULDIV & BCD UNIT)
    // ------------------------------------------------------------------------
    wire [31:0] alu_y;
    wire        alu_zero;
    alu u_alu (
        .a(rs_v),
        .b(alu_src ? imm_x : rt_v),
        .shamt(f_sh),
        .ctl(alu_ctl),
        .y(alu_y),
        .zero(alu_zero)
    );

    wire [31:0] mul_y, lo, hi, bcd_y;
    wire        md_busy, md_done, bcd_busy, bcd_done;
    wire        is_div = (multi == 2'b01);
    wire        is_bcd = (multi == 2'b10);

    muldiv u_md (
        .clk(clk),
        .rst(rst),
        .ce(ph_a),
        .start(is_div && !started),
        .a(rs_v),
        .b(rt_v),
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
        .ce(ph_a),
        .start(is_bcd && !started),
        .x(rs_v),
        .busy(bcd_busy),
        .done(bcd_done),
        .y(bcd_y)
    );

    wire mdone = is_div ? md_done : is_bcd ? bcd_done : 1'b0;
    // Tín hiệu dừng CPU khi đang thực thi lệnh đa chu kỳ chưa hoàn tất
    assign stall = (multi != 2'b00) && !mdone;

    // ------------------------------------------------------------------------
    // COPROCESSOR 0 (CP0 REGISTERS)
    // ------------------------------------------------------------------------
    // Đọc các thanh ghi CP0 qua lệnh mfc0: $12 Status, $13 Cause, $14 EPC
    reg [31:0] cp0_rd;
    always @* begin
        case (f_rd)
            5'd12:   cp0_rd = {30'd0, status};
            5'd13:   cp0_rd = {16'd0, irq_ip, 8'd0};
            5'd14:   cp0_rd = epc;
            default: cp0_rd = 32'd0;
        endcase
    end

    // ------------------------------------------------------------------------
    // BỘ NHỚ DỮ LIỆU & GIAO DIỆN BUS MMIO (PHA B CHỐT ĐỊA CHỈ)
    // ------------------------------------------------------------------------
    wire [31:0] maddr   = alu_y;
    wire        in_dmem = (maddr[31:12] == 20'd0);
    wire        in_mmio = (maddr[31:8] == 24'hFFFFFF);
    
    assign bus_addr  = {maddr[7:2], 2'b00};
    assign bus_wdata = rt_v;
    assign bus_we    = ph_b && mem_write && in_mmio;
    assign bus_re    = ph_b && mem_read  && in_mmio;

    wire [31:0] load_v = (lsel == 2'b01) ? dmem_q : 
                         (lsel == 2'b10) ? bus_rdata : 32'd0;

    // ------------------------------------------------------------------------
    // MẠCH CHỌN KẾT QUẢ GHI LẠI (WRITE-BACK MULTIPLEXER)
    // ------------------------------------------------------------------------
    reg [31:0] res;
    always @* begin
        case (res_sel)
            3'd1:    res = mul_y;
            3'd2:    res = hi;
            3'd3:    res = lo;
            3'd4:    res = bcd_y;
            3'd5:    res = cp0_rd;
            3'd6:    res = pc + 32'd4;
            default: res = alu_y;
        endcase
    end
    assign wb = mem_to_reg ? load_v : res;

    // ------------------------------------------------------------------------
    // TÍNH TOÁN BỘ ĐẾM CHƯƠNG TRÌNH KẾ TIẾP (NEXT PC LOGIC)
    // ------------------------------------------------------------------------
    wire [31:0] pc4  = pc + 32'd4;
    wire        eq   = (rs_v == rt_v);
    wire        take = (branch == 2'b01 && eq) || (branch == 2'b10 && !eq);
    
    reg  [31:0] next_pc;
    always @* begin
        if (rst)                  next_pc = 32'd0;
        else if (stall)           next_pc = pc;
        else if (cp0_op == 2'b10) next_pc = epc;
        else if (jump_reg)        next_pc = {rs_v[31:2], 2'b00};
        else if (jump)            next_pc = {pc4[31:28], instr[25:0], 2'b00};
        else if (take)            next_pc = pc4 + {imm_x[29:0], 2'b00};
        else                      next_pc = pc4;
    end

    // Điều kiện tiếp nhận ngắt
    wire        take_irq = irq && status[0] && !status[1] && !stall && (cp0_op == 2'b00);
    wire [31:0] pc_new   = take_irq ? 32'h0000_0180 : next_pc;

    assign pc_out = pc;
    assign retire = ph_a && !stall;

    // ------------------------------------------------------------------------
    // KHỞI TẠO BỘ NHỚ VÀ TIẾN TRÌNH TUẦN TỰ (SEQUENTIAL LOGIC)
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

    // Cổng đọc IMEM chốt tại cạnh sườn lên
    always @(posedge clk)
        if (rst || ph_a) instr <= imem[rst ? {G_IMEM_AW{1'b0}} : pc_new[G_IMEM_AW+1:2]];

    always @(posedge clk) begin
        if (rst) begin
            pc      <= 32'd0;
            phb     <= 1'b1;
            started <= 1'b0;
            status  <= 2'b00;
            epc     <= 32'd0;
            lsel    <= 2'b00;
            dmem_q  <= 32'd0;
        end else begin
            if (ph_b) begin
                // Pha B: Truy xuất bộ nhớ DMEM / chuẩn bị đọc MMIO
                if (in_dmem) begin
                    if (mem_write) dmem[maddr[11:2]] <= rt_v;
                    if (mem_read)  dmem_q            <= dmem[maddr[11:2]];
                    lsel <= mem_read ? 2'b01 : 2'b00;
                end else if (in_mmio) begin
                    lsel <= mem_read ? 2'b10 : 2'b00;
                end else begin
                    lsel <= 2'b00;
                end
                phb <= 1'b0; // Chuyển sang Pha A ở cạnh tiếp theo
            end else if (ph_a) begin
                // Pha A: Cập nhật PC, thanh ghi và xử lý ngắt
                if (take_irq) begin
                    epc       <= next_pc;
                    status[1] <= 1'b1; // Bật cờ EXL khóa ngắt
                    pc        <= 32'h0000_0180;
                    started   <= 1'b0;
                end else if (!stall) begin
                    pc <= next_pc;
                    if (cp0_op == 2'b01 && f_rd == 5'd12) status <= rt_v[1:0]; // Lệnh mtc0 Status
                    if (cp0_op == 2'b10)                  status[1] <= 1'b0;   // Lệnh eret xóa cờ EXL
                    started <= 1'b0;
                end else begin
                    started <= 1'b1; // Đang stall lệnh đa chu kỳ
                end
                phb <= 1'b1; // Chuyển sang Pha B ở chu kỳ tiếp theo
            end
        end
    end

    wire unused_ok = &{1'b0, alu_zero, md_busy, bcd_busy, uses_rs, uses_rt, imm_x[31:30], maddr[1:0]};

`ifndef SYNTHESIS
    // ------------------------------------------------------------------------
    // GHI VẾT MÔ PHỎNG (SIMULATION TRACE)
    // ------------------------------------------------------------------------
    integer tf, cyc;
    initial begin
        tf  = 0;
        cyc = 0;
        if (TRACE_FILE != "") tf = $fopen(TRACE_FILE, "w");
    end
    always @(posedge clk) begin
        if (rst) cyc <= 0; else cyc <= cyc + 1;
        if (!rst && retire) begin
            if (!valid) $display("ASSERT lenh la: pc=%h instr=%h", pc, instr);
            if (tf != 0)
                $fwrite(tf, "%0d,%h,%h,%0d,%h,%s,%h,%h\n", cyc, pc, instr,
                        (reg_write && wa != 0) ? wa : 5'd0,
                        (reg_write && wa != 0) ? wb : 32'd0,
                        mem_read ? "R" : mem_write ? "W" : "-",
                        (mem_read || mem_write) ? {maddr[31:2], 2'b00} : 32'd0,
                        mem_read ? load_v : mem_write ? rt_v : 32'd0);
            if (tf != 0 && take_irq)
                $fwrite(tf, "%0d,00000180,INTERRUPT,0,00000000,-,00000000,00000000\n", cyc);
        end
    end
`endif

endmodule
