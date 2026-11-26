// tb/bcd_tb.v — Kiểm thử Bộ chuyển đổi Nhị phân sang BCD (BCD Converter Testbench)
// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN TESTBENCH:  tb/bcd_tb.v — Kiểm thử Bộ Chuyển đổi Nhị phân sang BCD (BCD Converter Testbench)
// CHUYÊN ĐỀ KTMT: Chương 03: Số học máy tính & Thuật toán chuyển đổi cơ số (Double-Dabble / Shift-Add-3)
// VAI TRÒ:        Kiểm chứng tính đúng đắn và số chu kỳ thực thi của khối chuyển đổi nhị phân sang BCD
// MÔ TẢ:          - Kiểm thử 3,134 ca mẫu trong testbench/vectors/bcd.txt cho cả phiên bản tuần tự (bcd.v) và tổ hợp (bcd_comb.v).
//                 - Đo đạc chính xác số chu kỳ hoàn thành của bản tuần tự (28 chu kỳ CPU, báo busy/done).
//                 - Kiểm thử bổ sung 100,000 số nguyên ngẫu nhiên đối chiếu hàm chia dư tiêu chuẩn.
// ============================================================================
`timescale 1ns/1ps
module bcd_tb;
    reg         clk = 0, rst = 1, start = 0;
    reg  [31:0] x = 0, xc = 0;
    wire        busy, done, busy_c, done_c;
    wire [31:0] y, yc;

    bcd_unit #(.G_COMB(0)) dut  (.clk(clk), .rst(rst), .ce(1'b1), .start(start), .x(x),
                                 .busy(busy), .done(done), .y(y));
    bcd_unit #(.G_COMB(1)) dutc (.clk(clk), .rst(rst), .ce(1'b1), .start(1'b1), .x(xc),
                                 .busy(busy_c), .done(done_c), .y(yc));

    always #10 clk = ~clk;

    integer fd, c, r, n, nerr, ncase, cyc, k;
    reg [8*200:1] rest;
    reg [31:0] e_x, e_y, got;

    task check(input cond, input [8*40:1] what);
        begin
            n = n + 1;
            if (!cond) begin
                nerr = nerr + 1;
                if (nerr <= 10) $display("loi %0s: x=%h y=%h yc=%h cyc=%0d (can %h)", what, e_x, got, yc, cyc, e_y);
            end
        end
    endtask

    function [31:0] golden(input [31:0] v);
        integer i;
        reg [31:0] t;
        begin
            if (v > 99999999) golden = 32'hFFFFFFFF;
            else begin
                t = v; golden = 0;
                for (i = 0; i < 8; i = i + 1) begin golden[4*i +: 4] = t % 10; t = t / 10; end
            end
        end
    endfunction

    // giao thức CPU: start 1 chu kỳ, x đổi thành rác ngay sau đó; đọc y ở chu kỳ done
    task run_seq(input [31:0] v);
        begin
            x = v; start = 1; cyc = 1;
            #1;
            while (!done) begin
                @(negedge clk); start = 0; x = 32'hDEADBEEF; cyc = cyc + 1; #1;
            end
            got = y;
            @(negedge clk); start = 0;
        end
    endtask

    initial begin
        n = 0; nerr = 0; ncase = 0;
        repeat (2) @(negedge clk);
        rst = 0;
        fd = $fopen("testbench/vectors/bcd.txt", "r");
        if (fd == 0) begin $display("FAIL bcd_tb khong mo duoc testbench/vectors/bcd.txt"); $finish; end
        while (!$feof(fd)) begin
            c = $fgetc(fd);
            if (c == "#" || c == "\n") r = $fgets(rest, fd);
            else if (c != -1) begin
                r = $ungetc(c, fd);
                r = $fscanf(fd, "%h %h\n", e_x, e_y);
                ncase = ncase + 1;
                run_seq(e_x);
                check(got === e_y, "tuan tu vs bcd.txt");
                check(cyc == ((e_x > 99999999) ? 1 : 28), "so chu ky tuan tu");
                xc = e_x; #1;
                check(yc === e_y && !busy_c, "to hop vs bcd.txt");
                check(golden(e_x) === e_y, "golden tb vs bcd.txt");
            end
        end
        $fclose(fd);
        check(ncase == 3134, "du 3134 ca");

        // bản tổ hợp: 10^5 số ngẫu nhiên trong miền hợp lệ (hoặc quét hết với +full)
        if ($test$plusargs("full")) begin
            for (k = 0; k < 100000000; k = k + 1) begin
                xc = k; #1; e_x = xc; e_y = golden(xc); got = yc;
                check(yc === e_y, "to hop quet het");
            end
        end else begin
            for (k = 0; k < 100000; k = k + 1) begin
                xc = {$random} % 100000000; #1; e_x = xc; e_y = golden(xc); got = yc;
                check(yc === e_y, "to hop ngau nhien");
            end
        end

        if (nerr == 0) $display("PASS bcd_tb %0d", n);
        else $display("FAIL bcd_tb %0d loi / %0d kiem tra", nerr, n);
        $finish;
    end
endmodule
