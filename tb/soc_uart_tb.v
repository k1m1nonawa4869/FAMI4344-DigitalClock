// (fw: fw/tests/soc/uart.s)
// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN TESTBENCH:  tb/soc_uart_tb.v — Kiểm thử Giao tiếp Nối tiếp UART Tích hợp trên SoC
// CHUYÊN ĐỀ KTMT: Chương 05: Hệ thống Vào/Ra & Giao thức Truyền thông Nối tiếp Không đồng bộ (UART Protocol)
// VAI TRÒ:        Kiểm chứng truyền nhận dữ liệu UART tự kiểm tra qua cơ chế đấu vòng loopback trên SoC
// MÔ TẢ:          - Nạp firmware tự kiểm fw/tests/soc/uart.s điều khiển truyền nhận gói tin qua bus MMIO.
//                 - Đấu vòng chân phát UART TX sang chân thu UART RX và kiểm tra tính toàn vẹn của chuỗi dữ liệu truyền.
//                 - Xác thực hoạt động của bộ đệm hàng đợi FIFO UART và cờ trạng thái truyền nhận.
// ============================================================================
`timescale 1ns/1ps
module soc_uart_tb;
    reg  clk = 0, rst_in = 1;
    wire [7:0] an;
    wire [6:0] seg;
    wire       dp, line;

    soc_top #(.G_N(50), .G_SLOT(40), .G_BLANK(4), .G_BIT(8)) dut (.clk(clk), .rst_in(rst_in), .btn(4'b0), .an(an), .seg(seg),
                                                                  .dp(dp), .beep(), .uart_rx(line), .uart_tx(line));

    always #10 clk = ~clk;

    integer n, nerr, nbad, cyc, i, nframe;
    reg [8*256:1] fimem, ftrace;
    reg [31:0] v0;
    reg [8*40:1] name [0:5];

    task check(input cond, input [8*48:1] what);
        begin
            n = n + 1;
            if (!cond) begin nerr = nerr + 1; $display("loi %0s", what); end
        end
    endtask

    always @(posedge clk) if (!dut.rst) begin
        cyc <= cyc + 1;
        if (dut.u_cpu.retire && !dut.u_cpu.valid) nbad <= nbad + 1;
        if (dut.u_uart.t_load) nframe <= nframe + 1;
    end

    initial begin
        n = 0; nerr = 0; nbad = 0; cyc = 0; nframe = 0;
        name[0] = "reset: STATUS = TX_READY";        name[1] = "TX 0x48 -> vong lai -> RX";
        name[2] = "IRQ_PENDING bit 6 + 7";           name[3] = "3 byte lien dung thu tu";
        name[4] = "FIFO rong: RX = 0, STATUS = 4";   name[5] = "sw thu 3 khi day -> TX_DROP, xoa";
        if (!$value$plusargs("imem=%s", fimem)) begin $display("FAIL soc_uart_tb thieu +imem="); $finish; end
        #1;                                     // sau initial xóa imem của cpu_g1 (cùng t = 0 thì thứ tự tùy simulator)
        $readmemh(fimem, dut.u_cpu.imem);
        if ($value$plusargs("trace=%s", ftrace)) dut.u_cpu.tf = $fopen(ftrace, "w");   // trace isa-spec §8 cho cosim_iss
        repeat (6) @(negedge clk);
        rst_in = 0;
        while (!(dut.bus_we && dut.bus_addr == 8'h94) && cyc < 100000) @(negedge clk);   // sw dấu xong (−108)
        repeat (20) @(negedge clk);             // G2: lệnh trước sw đã qua WB
        v0 = dut.u_cpu.u_rf.r[2];
        check(cyc < 100000, "chay toi dau xong truoc 100000 chu ky");
        for (i = 0; i < 6; i = i + 1) check(v0[i], name[i]);
        check(nbad == 0, "khong lenh la");
        check(nframe == 6, "dung 6 khung tren day");
        $display("v0 = %h, %0d khung, %0d chu ky he thong", v0, nframe, cyc);
        if (nerr == 0) $display("PASS soc_uart_tb %0d", n);
        else $display("FAIL soc_uart_tb %0d loi / %0d kiem tra", nerr, n);
        $finish;
    end
endmodule
