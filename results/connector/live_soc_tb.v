// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     results/connector/live_soc_tb.v — Cầu Nối RTL Trực Tiếp (WatchChip Live Bridge)
// CHUYÊN ĐỀ KTMT: Chương 05: Hệ thống Vào/Ra (I/O) & Đồng thiết kế Phần cứng / Phần mềm
// VAI TRÒ:        Đưa toàn bộ chip WatchChip thật (source/soc_top.v + firmware/main.hex)
//                 chạy tương tác từng bước trong vvp, cấp tín hiệu LED vật lý + màu LED
//                 + âm thanh còi cho cả results/WatchChip.exe và results/clock_terminal.py.
// MÔ TẢ:          - Nạp mã máy MIPS32 (work/main.hex, biên dịch từ firmware/*.s) vào IMEM.
//                 - Đọc từng lệnh "<btn_mask> <n_ms>" từ stdin (MODE=bit0, A=bit1, B=bit2, C=bit3).
//                 - Mô phỏng đúng n_ms mili-giây của RTL (timebase, rtc, stopwatch, timer, alarm,
//                   buttons, display_ctrl, seg7_scan, beeper, uart, cpu_g1/cpu_pipe).
//                 - Xuất "F <t_ms> <S7..S0_hex> <lit_hex> <color_hex> <beep>" qua stdout:
//                   + <S7..S0_hex>, <lit_hex>: chụp trực tiếp từ chân an[7:0], seg[6:0], dp.
//                   + <color_hex>: đọc 2-bit V_COLOR (DMEM 0x788 = word 482) do firmware chỉnh khi bấm C.
// ============================================================================

`timescale 1ns/1ps

module live_soc_tb;

    // ------------------------------------------------------------------------
    // 1. THAM SỐ NÉN THỜI GIAN MÔ PHỎNG & RÀNG BUỘC QUÉT LED PWM
    // ------------------------------------------------------------------------
    // - G_N = 10: 10 chu kỳ clk / 1 ms mô phỏng (1 giây đồng hồ = 10.000 chu kỳ),
    //   giúp vvp chạy ~1,75x thời gian thực để GUI/Terminal giữ đúng nhịp 1 giây thật.
    // - G_SLOT = 20, G_BLANK = 4: Bắt buộc G_SLOT >= 20 để G_STEP = (20-4)/16 = 1 != 0
    //   trong source/seg7_scan.v; nếu G_SLOT < 17 thì mọi chữ số LED sẽ bị tắt tối.
    localparam G_N     = 10,
               G_SLOT  = 20,
               G_BLANK = 4,
               G_DIG   = 8,
               ROUND   = G_SLOT * G_DIG;        // 160 chu kỳ cho 1 vòng quét trọn 8 chữ số

    // ------------------------------------------------------------------------
    // 2. KHỞI TẠO TOÀN BỘ CHIP WATCHCHIP SOC (SOURCE/*.V + FIRMWARE)
    // ------------------------------------------------------------------------
    reg        clk    = 0;
    reg        rst_in = 1;
    reg  [3:0] btn    = 4'd0;                   // 4 nút vật lý: [0]=MODE, [1]=A, [2]=B, [3]=C
    wire [7:0] an;                              // 8 cực Anode chọn chữ số LED (tích cực cao)
    wire [6:0] seg;                             // 7 cực Cathode thanh đoạn {g,f,e,d,c,b,a}
    wire       dp, beep, utx;

    soc_top #(
        .G_N    (G_N),
        .G_SLOT (G_SLOT),
        .G_BLANK(G_BLANK),
        .G_BIT  (8)
    ) dut (
        .clk    (clk),
        .rst_in (rst_in),
        .btn    (btn),
        .an     (an),
        .seg    (seg),
        .dp     (dp),
        .beep   (beep),
        .uart_rx(1'b1),
        .uart_tx(utx)
    );

    always #10 clk = ~clk;                       // Xung hệ thống 50 MHz (chu kỳ 20 ns)

    // ------------------------------------------------------------------------
    // 3. CHỤP TÍN HIỆU CHÂN VẬT LÝ LED (ANODE / CATHODE / DP)
    // ------------------------------------------------------------------------
    // Không đọc thanh ghi hiển thị MMIO: chỉ quan sát chân an/seg/dp như màn LED thật.
    // Cập nhật ngay sau mỗi vòng quét ROUND chu kỳ để hàng 1/1000 s Stopwatch nhảy mượt 0..9.
    reg [63:0] cur       = 64'd0;
    reg [63:0] shown     = 64'd0;
    reg [7:0]  lit_cur   = 8'd0;
    reg [7:0]  lit_shown = 8'd0;
    integer    cyc = 0, t_ms = 0, i;

    always @(posedge clk) if (!dut.rst) begin
        if (dut.tick_ms) t_ms = t_ms + 1;
        for (i = 0; i < G_DIG; i = i + 1)
            if (an[i]) begin
                cur[8*i +: 8] = {dp, seg};      // Byte chữ số i = {chấm dp, g, f, e, d, c, b, a}
                lit_cur[i]    = 1'b1;           // Đánh dấu chữ số i đang bật sáng trong vòng quét
            end
        cyc = cyc + 1;
        if (cyc % ROUND == 0) begin
            shown     = cur;
            lit_shown = lit_cur;
            cur       = 64'd0;
            lit_cur   = 8'd0;
        end
    end

    // Tín hiệu màu LED (V_COLOR tại địa chỉ byte 0x788 = word 482 trong DMEM) do firmware quản lý
    wire [7:0] led_color = {6'd0, dut.u_cpu.dmem[482][1:0]};

    // ------------------------------------------------------------------------
    // 4. GIAO THỨC ỐNG NỐI STDIN / STDOUT CHO CẢ TERMINAL VÀ WATCHCHIP.EXE
    // ------------------------------------------------------------------------
    reg [8*256:1] fimem;
    integer       n_ms, mask, k, r;

    initial begin
        if (!$value$plusargs("imem=%s", fimem)) begin
            $display("ERR thieu +imem=");
            $finish;
        end
        #1;                                     // Chờ khối initial xóa IMEM trong lõi CPU chạy xong
        $readmemh(fimem, dut.u_cpu.imem);       // Nạp mã máy firmware MIPS32 (work/main.hex)
        repeat (6) @(negedge clk);
        rst_in = 0;                             // Nhả reset đồng bộ qua chuỗi 2-FF trong soc_top
        $display("READY");
        $fflush();

        // Không đặt '\n' ở cuối "$fscanf" vì ký tự trắng cuối khiến vvp chặn chờ trên ống pipe.
        while (1) begin
            r = $fscanf(32'h8000_0000, "%d %d", mask, n_ms);
            if (r != 2) begin
                $display("BYE");
                $finish;
            end
            btn = mask[3:0];                    // Đưa 4 bit nút bấm trực tiếp vào chân vật lý btn[3:0]
            for (k = 0; k < n_ms * G_N; k = k + 1) @(posedge clk);
            $display("F %0d %016h %02h %02h %b", t_ms, shown, lit_shown, led_color, beep);
            $fflush();
        end
    end

endmodule
