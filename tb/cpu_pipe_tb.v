// (cosim) tb/cpu_pipe_tb.v — Kiểm thử CPU MIPS 5 tầng Pipeline G2 (CPU Pipeline Co-simulation Testbench)
// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN TESTBENCH:  tb/cpu_pipe_tb.v — Kiểm thử CPU MIPS 5 Tầng Pipeline G2 (CPU Pipeline Co-simulation Testbench)
// CHUYÊN ĐỀ KTMT: Chương 04: Kiến trúc Vi xử lý 5 tầng Pipeline (IF-ID-EX-MEM-WB) & Giải quyết Xung đột
// VAI TRÒ:        Mô phỏng thực thi chương trình trên CPU Pipeline G2 và trích xuất vết thực thi đối chuẩn
// MÔ TẢ:          - Chạy mô phỏng các chương trình kiểm thử vi xử lý và các chuỗi lệnh bẫy xung đột dữ liệu/điều khiển.
//                 - Xác thực cơ chế chèn bọt trễ (Stall), chuyển tiếp dữ liệu (Forwarding) và xóa lệnh rẽ nhánh (Flush).
//                 - Kết xuất vết thực thi lệnh (trace CSV) và trạng thái kết thúc phục vụ đồng mô phỏng đối chuẩn với ISS.
// ============================================================================
`timescale 1ns/1ps
module cpu_pipe_tb;
    reg         clk = 0, rst = 1;
    wire [7:0]  bus_addr;
    wire [31:0] bus_wdata, pc;
    wire        bus_we, bus_re, div_dz, retire;
    reg  [31:0] rd_ram = 0;
    wire [31:0] rd_irq;
    wire [31:0] bus_rdata = rd_ram | rd_irq;
    wire        irq;
    wire [7:0]  irq_ip;
    reg  [7:0]  ev = 0, ev_bits = 0;
    reg  [31:0] cyc_cnt = 0;
    integer     ev_wait = -1;
    reg  [31:0] mmio [0:63];

    reg         cpu_ce = 1;
    integer     cediv = 1, cephase = 0;     // khởi tạo: X lan truyền qua cpu_ce làm lệch thời điểm retire giữa các simulator
    cpu_pipe dut (.clk(clk), .rst(rst), .cpu_ce(cpu_ce), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
                  .bus_we(bus_we), .bus_re(bus_re), .bus_rdata(bus_rdata), .irq(irq), .irq_ip(irq_ip),
                  .div_dz(div_dz), .pc_out(pc), .retire(retire));

    always #10 clk = ~clk;
    always @(posedge clk) cephase <= (cephase + 1) % cediv;
    always @* cpu_ce = (cephase == 0);

    irq_ctrl u_irq (.clk(clk), .rst(rst), .ev(ev), .cycle_count(cyc_cnt), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
                    .bus_we(bus_we), .bus_re(bus_re), .bus_rdata(rd_irq), .irq(irq), .ip(irq_ip));
    wire is_irq_reg = (bus_addr == 8'h44 || bus_addr == 8'h48 || bus_addr == 8'h4C);

    always @(posedge clk) begin
        cyc_cnt <= rst ? 32'd0 : cyc_cnt + 32'd1;
        if (bus_we && !is_irq_reg) mmio[bus_addr[7:2]] <= bus_wdata;
        if (bus_re) rd_ram <= is_irq_reg ? 32'd0 : mmio[bus_addr[7:2]];   // giữ tới lần đọc sau (mmio-map §2)
        ev <= 8'd0;
        if (bus_we && bus_addr == 8'hF0) begin
            if (bus_wdata[23:8] == 0) ev <= bus_wdata[7:0];
            else begin ev_wait <= bus_wdata[23:8] - 1; ev_bits <= bus_wdata[7:0]; end
        end else if (ev_wait == 0) begin ev <= ev_bits; ev_wait <= -1; end
        else if (ev_wait > 0) ev_wait <= ev_wait - 1;
    end

    reg [8*256:1] fimem, fdump, ftrace, fvcd;
    integer i, df, n, nerr, cyc, cpu_cyc, maxcyc, nstart, ncomp, nbus, mem_ops;
    reg [31:0] endpc;
    reg        has_end;

    task check(input cond, input [8*48:1] what);
        begin
            n = n + 1;
            if (!cond) begin
                nerr = nerr + 1;
                if (nerr <= 10) $display("loi %0s: pc=%h", what, pc);
            end
        end
    endtask

    // ---- đếm: khởi động mul/div/bcd, lệnh nhiều chu kỳ hoàn tất, bus MMIO
    wire ce_multi_done = cpu_ce && dut.idex_v && (dut.idex_multi != 2'b00) && !dut.stall_busy;
    always @(posedge clk) begin
        if (!rst) begin
            cyc <= cyc + 1;
            if (cpu_ce && (dut.md_go || dut.bc_go)) nstart <= nstart + 1;
            if (ce_multi_done) ncomp <= ncomp + 1;
            if (bus_we || bus_re) nbus <= nbus + 1;
            if (retire && (dut.mw_mrd || dut.mw_mwr) && dut.mw_addr[31:8] == 24'hFFFFFF) mem_ops <= mem_ops + 1;
        end
    end

    initial begin
        n = 0; nerr = 0; cyc = 0; cpu_cyc = 0; nstart = 0; ncomp = 0; nbus = 0; mem_ops = 0;
        for (i = 0; i < 64; i = i + 1) mmio[i] = 32'd0;
        if (!$value$plusargs("imem=%s", fimem)) begin $display("FAIL cpu_pipe_tb thieu +imem="); $finish; end
        if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 2000000;
        if (!$value$plusargs("cediv=%d", cediv)) cediv = 1;
        cephase = 0;
        has_end = $value$plusargs("end=%h", endpc);
        #1;                                     // sau initial xóa imem/dmem của cpu_pipe
        $readmemh(fimem, dut.imem);
        repeat (4) @(negedge clk);
        if (has_end) dut.tr_end = endpc;        // lệnh có PC ≥ end không vào trace
        if ($value$plusargs("trace=%s", ftrace)) dut.tf = $fopen(ftrace, "w");
        rst = 0;
        if ($value$plusargs("vcd=%s", fvcd)) begin
            $dumpfile(fvcd);
            $dumpvars(0, cpu_pipe_tb);
        end

        // chạy tới khi lệnh có PC ≥ end tới EX/MEM (mọi lệnh trước nó, kể cả nhánh, đã xong; lệnh sai đường bị xóa trước đó),
        // rồi chạy nốt 8 bước CPU
        while (!(has_end && dut.exm_v && dut.exm_pc >= endpc) && cyc < maxcyc) @(negedge clk);
        check(cyc < maxcyc, "chay xong truoc maxcyc");
        repeat (8 * cediv) @(negedge clk);
        if (dut.tf != 0) begin $fclose(dut.tf); dut.tf = 0; end
        cpu_cyc = cyc / cediv;
        check(nstart == ncomp, "div/bcd: 1 xung start moi lenh");
        check(nbus == mem_ops, "lw/sw MMIO: bus 1 chu ky moi lenh (ke ca lenh bi xoa)");

        if ($value$plusargs("dump=%s", fdump)) begin
            df = $fopen(fdump, "w");
            for (i = 0; i < 32; i = i + 1) $fwrite(df, "R %0d %h\n", i, dut.u_rf.r[i]);
            $fwrite(df, "HI %h\nLO %h\n", dut.hi, dut.lo);
            for (i = 0; i < 1024; i = i + 1)
                if (dut.dmem[i] != 0) $fwrite(df, "M %h %h\n", 4 * i, dut.dmem[i]);
            for (i = 0; i < 64; i = i + 1)
                if (mmio[i] != 0) $fwrite(df, "IO %h %h\n", 32'hFFFFFF00 + 4 * i, mmio[i]);
            $fwrite(df, "IC %0d\nCPUCYC %0d\n", dut.n_ret, cpu_cyc);
            $fclose(df);
        end
        $display("ic=%0d cpu_cyc=%0d", dut.n_ret, cpu_cyc);
        if (nerr == 0) $display("PASS cpu_pipe_tb %0d", n);
        else $display("FAIL cpu_pipe_tb %0d loi / %0d kiem tra", nerr, n);
        $finish;
    end
endmodule
