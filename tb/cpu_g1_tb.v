// (cosim) tb/cpu_g1_tb.v — Kiểm thử CPU MIPS Đa chu kỳ G1 (CPU G1 Co-simulation Testbench)
// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN TESTBENCH:  tb/cpu_g1_tb.v — Kiểm thử CPU MIPS Đa Chu kỳ G1 (CPU G1 Co-simulation Testbench)
// CHUYÊN ĐỀ KTMT: Chương 04: Thiết kế Vi xử lý MIPS Đa chu kỳ & Chương 06: Kiểm chứng phần cứng
// VAI TRÒ:        Mô phỏng thực thi chương trình hợp ngữ trên CPU G1 và kết xuất trạng thái thanh ghi/bộ nhớ
// MÔ TẢ:          - Nạp mã máy nhị phân (.hex) vào bộ nhớ lệnh IMEM và chạy mô phỏng cho tới điểm kết thúc chương trình.
//                 - Kết xuất toàn bộ trạng thái 32 thanh ghi (GPR), thanh ghi HI/LO, bộ nhớ DMEM và số chu kỳ.
//                 - Phục vụ kịch bản đồng mô phỏng tự động so sánh độc lập với kết quả của trình mô phỏng MARS/ISS.
// ============================================================================
`timescale 1ns/1ps
module cpu_g1_tb;
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
    integer     cediv, cephase;
    cpu_g1 dut (.clk(clk), .rst(rst), .cpu_ce(cpu_ce), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
                .bus_we(bus_we), .bus_re(bus_re), .bus_rdata(bus_rdata), .irq(irq), .irq_ip(irq_ip),
                .div_dz(div_dz), .pc_out(pc), .retire(retire));

    always #10 clk = ~clk;
    always @(posedge clk) begin
        cephase <= (cephase + 1) % cediv;
    end
    always @* cpu_ce = (cephase == 0);

    irq_ctrl u_irq (.clk(clk), .rst(rst), .ev(ev), .cycle_count(cyc_cnt), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
                    .bus_we(bus_we), .bus_re(bus_re), .bus_rdata(rd_irq), .irq(irq), .ip(irq_ip));
    wire is_irq_reg = (bus_addr == 8'h44 || bus_addr == 8'h48 || bus_addr == 8'h4C);

    always @(posedge clk) begin
        cyc_cnt <= rst ? 32'd0 : cyc_cnt + 32'd1;
        if (bus_we && !is_irq_reg) mmio[bus_addr[7:2]] <= bus_wdata;
        if (bus_re) rd_ram <= is_irq_reg ? 32'd0 : mmio[bus_addr[7:2]];   // giữ tới lần đọc sau (CPU lấy ở pha A, có thể nhiều chu kỳ sau)
        // máy phát sự kiện ngắt của tb
        ev <= 8'd0;
        if (bus_we && bus_addr == 8'hF0) begin
            if (bus_wdata[23:8] == 0) ev <= bus_wdata[7:0];
            else begin ev_wait <= bus_wdata[23:8] - 1; ev_bits <= bus_wdata[7:0]; end
        end else if (ev_wait == 0) begin ev <= ev_bits; ev_wait <= -1; end
        else if (ev_wait > 0) ev_wait <= ev_wait - 1;
    end

    reg [8*256:1] fimem, fdump, ftrace;
    integer i, df, n, nerr, cyc, cpu_cyc, maxcyc, ic, ic_end, cc_end, hold, nstart, nmulti, nbus, mem_ops;
    reg [31:0] endpc;
    reg        has_end;

    task check(input cond, input [8*48:1] what);
        begin
            n = n + 1;
            if (!cond) begin
                nerr = nerr + 1;
                if (nerr <= 10) $display("loi %0s: pc=%h instr=%h hold=%0d", what, pc, dut.instr, hold);
            end
        end
    endtask

    // ---- theo dõi từng chu kỳ CPU (pha A = cạnh có retire hoặc stall)
    wire ph_a = !rst && dut.ph_a;
    wire is_multi = (dut.multi != 2'b00);
    always @(posedge clk) begin
        if (!rst) begin
            cyc <= cyc + 1;
            if (dut.u_md.ce && dut.u_md.start && !dut.u_md.busy) nstart <= nstart + 1;
            if (dut.u_bcd.ce && dut.u_bcd.start && !dut.u_bcd.busy) nstart <= nstart + 1;
            if (bus_we || bus_re) nbus <= nbus + 1;
        end
    end
    always @(posedge clk) if (ph_a) begin
        cpu_cyc <= cpu_cyc + 1;
        if (retire) begin
            ic <= ic + 1;
            if (dut.mem_read || dut.mem_write) if (dut.in_mmio) mem_ops <= mem_ops + 1;
            if (is_multi) begin
                nmulti <= nmulti + 1;
                if (dut.multi == 2'b01)
                    check(hold + 1 == ((dut.rt_v == 0) ? 1 : 33), "div dung 33 chu ky CPU (chia 0: 1)");
                else if (dut.G_BCD_COMB == 0)
                    check(hold + 1 == ((dut.rs_v > 99999999) ? 1 : 28), "bcd dung 28 chu ky CPU (tran: 1)");
            end
            hold <= 0;
        end else hold <= hold + 1;
    end

    initial begin
        n = 0; nerr = 0; cyc = 0; cpu_cyc = 0; ic = 0; hold = 0; nstart = 0; nmulti = 0; nbus = 0; mem_ops = 0;
        for (i = 0; i < 64; i = i + 1) mmio[i] = 32'd0;
        if (!$value$plusargs("imem=%s", fimem)) begin $display("FAIL cpu_g1_tb thieu +imem="); $finish; end
        if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 2000000;
        if (!$value$plusargs("cediv=%d", cediv)) cediv = 1;
        cephase = 0;
        has_end = $value$plusargs("end=%h", endpc);
        #1;                                     // sau initial xóa imem của cpu_g1 (cùng t = 0 thì thứ tự tùy simulator)
        $readmemh(fimem, dut.imem);
        repeat (4) @(negedge clk);              // sau initial của cpu_g1 (tf = 0) mới mở trace
        if ($value$plusargs("trace=%s", ftrace)) dut.tf = $fopen(ftrace, "w");
        rst = 0;

        // chạy tới khi PC = end, hoặc gặp "j ." (nhảy về chính nó), hoặc hết giờ
        while (!(has_end && pc == endpc) &&
               !(dut.jump && dut.instr[25:0] == pc[27:2] && dut.retire) && cyc < maxcyc)
            @(negedge clk);
        ic_end = ic; cc_end = cpu_cyc;           // chưa tính lệnh ở PC = end (2 chu kỳ chạy thêm bên dưới)
        if (dut.tf != 0) begin $fclose(dut.tf); dut.tf = 0; end
        check(cyc < maxcyc, "chay xong truoc maxcyc");
        repeat (2) @(negedge clk);
        check(nstart == nmulti, "div/bcd: dung 1 xung start moi lenh");
        check(nbus == mem_ops, "lw/sw MMIO: bus_re/bus_we dung 1 chu ky moi lenh");

        if ($value$plusargs("dump=%s", fdump)) begin
            df = $fopen(fdump, "w");
            for (i = 0; i < 32; i = i + 1) $fwrite(df, "R %0d %h\n", i, dut.u_rf.r[i]);
            $fwrite(df, "HI %h\nLO %h\n", dut.hi, dut.lo);
            for (i = 0; i < 1024; i = i + 1)
                if (dut.dmem[i] != 0) $fwrite(df, "M %h %h\n", 4 * i, dut.dmem[i]);
            for (i = 0; i < 64; i = i + 1)
                if (mmio[i] != 0) $fwrite(df, "IO %h %h\n", 32'hFFFFFF00 + 4 * i, mmio[i]);
            $fwrite(df, "IC %0d\nCPUCYC %0d\n", ic_end, cc_end);
            $fclose(df);
        end
        $display("ic=%0d cpu_cyc=%0d", ic_end, cc_end);
        if (nerr == 0) $display("PASS cpu_g1_tb %0d", n);
        else $display("FAIL cpu_g1_tb %0d loi / %0d kiem tra", nerr, n);
        $finish;
    end
endmodule
