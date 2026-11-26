// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN MODULE:     tb/screen_dump.v — Màn hình ảo chụp tín hiệu quét LED 7 đoạn
// CHUYÊN ĐỀ KTMT: Chương 5 (Hệ thống I/O & Ngoại vi hiển thị)
// VAI TRÒ:        Giám sát trực tiếp các chân vật lý Anode (an) và Cathode (seg, dp)
//                 tại ngõ ra của SoC mà không can thiệp vào thanh ghi MMIO.
//                 Tái tạo lại chính xác hình ảnh hiển thị của đồng hồ LED 7 thanh
//                 sau mỗi chu kỳ quét 8 khe và ghi vết ra file log (screen.log).
// ============================================================================
module screen_dump #(
    parameter G_DIGITS = 8,
    parameter G_SLOT   = 40,
    parameter FILE     = "work/screen.log"
) (
    input wire                clk,
    input wire                rst,
    input wire                tick_ms,
    input wire [G_DIGITS-1:0] an,      // mức cao = sáng
    input wire [6:0]          seg,
    input wire                dp
);
    localparam ROUND = G_SLOT * G_DIGITS;

    integer fd, cyc, t_ms, i, nframes;
    reg [8*G_DIGITS-1:0] cur, frame, last;
    reg [G_DIGITS-1:0]   lit_cur, lit, lit_last;
    reg                  have_last;
    event                round;                       // mỗi vòng quét xong (frame, lit vừa cập nhật): tb so ảnh (D7)

    initial begin
        fd = $fopen(FILE, "w");
        $fdisplay(fd, "# t_ms S7..S0 LIT  | Si = {dp,gfedcba} hex, LIT bit i = chu so i co sang");
        cyc = 0; t_ms = 0; nframes = 0; have_last = 0;
        cur = 0; lit_cur = 0; frame = 0; lit = 0; last = 0; lit_last = 0;
    end

    always @(posedge clk) begin
        if (rst) begin
            cyc = 0; cur = 0; lit_cur = 0;
        end else begin
            if (tick_ms) t_ms = t_ms + 1;
            for (i = 0; i < G_DIGITS; i = i + 1)
                if (an[i]) begin
                    cur[8*i +: 8] = {dp, seg};
                    lit_cur[i]    = 1'b1;
                end
            cyc = cyc + 1;
            if (cyc % ROUND == 0) begin
                frame = cur; lit = lit_cur;
                -> round;
                if (!have_last || frame !== last || lit !== lit_last) begin
                    $fwrite(fd, "%0d", t_ms);
                    for (i = G_DIGITS - 1; i >= 0; i = i - 1) $fwrite(fd, " %h", frame[8*i +: 8]);
                    $fwrite(fd, " %h\n", lit);
                    last = frame; lit_last = lit; have_last = 1;
                    nframes = nframes + 1;
                end
                cur = 0; lit_cur = 0;
            end
        end
    end
endmodule
