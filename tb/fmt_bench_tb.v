// (fw: fw/fmt.s)
// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN TESTBENCH:  tb/fmt_bench_tb.v — Đo đạc Hiệu năng Thuật toán Định dạng Thời gian (Format Benchmark Testbench)
// CHUYÊN ĐỀ KTMT: Chương 01: Đánh giá hiệu năng máy tính & Chương 04: Tối ưu hóa phần mềm hợp ngữ MIPS
// VAI TRÒ:        Đo đạc chính xác số chu kỳ CPU tiêu tốn cho 3 thuật toán chuyển đổi thời gian sang chữ số
// MÔ TẢ:          - Chạy firmware fw/fmt.s trên hệ thống SoC đo đạc chu kỳ thực tế qua thanh ghi CYCLE_COUNT.
//                 - So sánh 3 phương pháp: Thuật toán chia phần mềm (fmt_div), Thuật toán BCD phần mềm (fmt_bcd),
//                   và Cơ chế tăng tốc đọc trực tiếp từ RTC BCD phần cứng (fmt_hw).
//                 - Cung cấp số liệu định lượng phục vụ bảng phân tích không gian thiết kế (DSE Table).
// ============================================================================
`timescale 1ns/1ps
module fmt_bench_tb;
    reg  clk = 0, rst_in = 1;
    wire [7:0] an;
    wire [6:0] seg;
    wire       dp;

`ifdef BCD_COMB
    localparam COMB = 1;
`else
    localparam COMB = 0;
`endif
    soc_top #(.G_N(50000), .G_SLOT(40), .G_BLANK(4), .G_BCD_RTC(1), .G_BCD_COMB(COMB)) dut (
        .clk(clk), .rst_in(rst_in), .btn(4'b0), .an(an), .seg(seg), .dp(dp), .beep(), .uart_rx(1'b1), .uart_tx());

    always #10 clk = ~clk;

    integer n, nerr, nbad, cyc, i, nfr;
    reg [8*256:1] fimem, ftrace;
    reg [63:0] fr [0:7];
    reg [63:0] exp [0:6];
    reg [31:0] base, c [1:7];

    task check(input cond, input [8*48:1] what);
        begin
            n = n + 1;
            if (!cond) begin nerr = nerr + 1; $display("loi %0s", what); end
        end
    endtask

    always @(posedge clk) if (!dut.rst) begin
        cyc <= cyc + 1;
        if (dut.u_cpu.retire && !dut.u_cpu.valid) nbad <= nbad + 1;
        if (dut.bus_we && dut.bus_addr == 8'h78 && nfr < 8) begin       // DISP7 = khung xong
            #1 fr[nfr] = dut.u_disp.disp;
            nfr = nfr + 1;
        end
    end

    initial begin
        n = 0; nerr = 0; nbad = 0; cyc = 0; nfr = 0;
        exp[0] = 64'h1A1A_0080_0080_0000;  exp[1] = exp[0];                // 00:00:00
        exp[2] = 64'h1A1A_0182_0384_0506;  exp[3] = exp[2];                // 12:34:56
        exp[4] = 64'h1A1A_0283_0589_0509;  exp[5] = exp[4];                // 23:59:59
        exp[6] = exp[2];                                                   // hw: RTC_BCD 12:34:56.789
        if (!$value$plusargs("imem=%s", fimem)) begin $display("FAIL fmt_bench_tb thieu +imem="); $finish; end
        #1;
        $readmemh(fimem, dut.u_cpu.imem);
`ifdef SLOW
        dut.u_cpu.dmem[12'h7f0 >> 2] = 1526;
`endif
        if ($value$plusargs("trace=%s", ftrace)) dut.u_cpu.tf = $fopen(ftrace, "w");
        repeat (6) @(negedge clk);
        rst_in = 0;
        while (!(dut.bus_we && dut.bus_addr == 8'h94) && cyc < 10000000) @(negedge clk);  // sw dấu xong (−108)
        repeat (20) @(negedge clk);
        check(cyc < 10000000, "chay toi dau xong truoc 10^7 chu ky");
        check(nfr == 7, "dung 7 khung");
        for (i = 0; i < 7; i = i + 1)
            if (fr[i] !== exp[i]) begin
                check(0, "khung sai");
                $display("  khung %0d: %h, mong %h", i, fr[i], exp[i]);
            end else n = n + 1;
        check(nbad == 0, "khong lenh la");
        base = dut.u_cpu.dmem[64];
        for (i = 1; i <= 7; i = i + 1) c[i] = dut.u_cpu.dmem[64 + i] - base;
        $display("core G%0d, D = %0d, bcd %s: nen (jal+jr+lw) %0d chu ky he thong", dut.G_CORE, dut.u_regs.d, COMB ? "to hop" : "tuan tu", base);
        $display("  fmt_div  %0d %0d %0d   fmt_bcd  %0d %0d %0d   fmt_hw  %0d   (0 / 12:34:56.789 / 23:59:59.999)",
                 c[1], c[3], c[5], c[2], c[4], c[6], c[7]);
        check(c[1] == c[3] && c[3] == c[5] && c[2] == c[4] && c[4] == c[6], "chi phi khong phu thuoc gia tri");
        if (nerr == 0) $display("PASS fmt_bench_tb %0d", n);
        else $display("FAIL fmt_bench_tb %0d loi / %0d kiem tra", nerr, n);
        $finish;
    end
endmodule
