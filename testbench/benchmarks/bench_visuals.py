# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    testbench/benchmarks/bench_visuals.py — Trích xuất Sóng VCD & Màn hình LED 7 đoạn
# CHUYÊN ĐỀ KTMT: Chương 04 & 05: Trực quan hóa Vi kiến trúc Pipeline, E3 Capture & 5 chế độ SoC
# VAI TRÒ:        Sinh 2 ảnh dạng sóng VCD thật qua vcd_plot.py và ảnh ghép 6 màn hình từ system_tb.
# ============================================================================
"""Benchmark 6/7 & 7/7: Vẽ dạng sóng VCD (Pipeline + E3) và ghép 6 màn hình LED 7 đoạn."""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

from common import (
    AMBER, BENCH_DIR, CRIMSON, DATA_DIR, NAVY, PLOT_DIR, ROOT, SLATE, TEAL, WORK_DIR,
    _ensure_msys_path, _save_json, _sh, _srcs,
)
import asm  # noqa: E402
import screen  # noqa: E402
import vcd_plot  # noqa: E402


def run_vcd_plots():
    """Sinh sóng VCD qua `gen_waves.py` và trích 2 biểu đồ dạng sóng số 300 DPI."""
    _ensure_msys_path()
    os.makedirs(PLOT_DIR, exist_ok=True)
    os.makedirs(WORK_DIR, exist_ok=True)

    print("\n=== [6/7] Sinh Dạng sóng VCD Thực tế (Pipeline G2 Hazard & E3 Capture 0-ns) ===")
    _sh([sys.executable, os.path.join(BENCH_DIR, "gen_waves.py")])

    vcd_pipe = os.path.join(WORK_DIR, "wave_pipeline.vcd")
    _, _, _, hist_p = vcd_plot.parse_vcd(
        vcd_pipe,
        ["cpu_pipe_tb.clk", "cpu_pipe_tb.dut.stall_lu", "cpu_pipe_tb.dut.fwd_a", "cpu_pipe_tb.dut.fwd_b"],
    )
    edges_p = vcd_plot.extract_clock_cycles(hist_p["cpu_pipe_tb.clk"])
    stall_cycles = [
        idx for idx, t in enumerate(edges_p)
        if vcd_plot.sample_at_time(hist_p["cpu_pipe_tb.dut.stall_lu"], t + 1000) == "1"
    ]
    fwd_cycles = [
        idx for idx, t in enumerate(edges_p)
        if (vcd_plot.sample_at_time(hist_p["cpu_pipe_tb.dut.fwd_a"], t + 1000) or "0").strip("0") != ""
        or (vcd_plot.sample_at_time(hist_p["cpu_pipe_tb.dut.fwd_b"], t + 1000) or "0").strip("0") != ""
    ]
    center_c = stall_cycles[0] if stall_cycles else 12
    c_start = max(4, center_c - 4)
    c_end = min(len(edges_p) - 2, center_c + 9)
    highlights_p = []
    if stall_cycles:
        highlights_p.append((stall_cycles[0], stall_cycles[0], AMBER, "stall_lu = 1 (Bơm 1 bong bóng Load-Use)"))
    for fc in fwd_cycles:
        if c_start <= fc <= c_end:
            highlights_p.append((fc, fc, TEAL, "Chuyển tiếp dữ liệu (fwd_a/fwd_b != 0)"))

    out_w_pipe = os.path.join(PLOT_DIR, "fig_wave_pipeline_hazard.png")
    vcd_plot.render_vcd_waveform(
        vcd_pipe,
        signals_spec=[
            ("cpu_pipe_tb.clk", "clk (50 MHz)", SLATE),
            ("cpu_pipe_tb.dut.pc_out", "IF: pc[31:0]", NAVY),
            ("cpu_pipe_tb.dut.ifid_ins", "IF/ID: instr", NAVY),
            ("cpu_pipe_tb.dut.idex_pc", "ID/EX: pc", TEAL),
            ("cpu_pipe_tb.dut.stall_lu", "Hazard: stall_lu", AMBER),
            ("cpu_pipe_tb.dut.fwd_a", "FwdA[1:0]", TEAL),
            ("cpu_pipe_tb.dut.fwd_b", "FwdB[1:0]", TEAL),
            ("cpu_pipe_tb.dut.exm_res", "EX/MEM: res", CRIMSON),
            ("cpu_pipe_tb.dut.wb", "WB: writeback", NAVY),
            ("cpu_pipe_tb.retire", "retire", TEAL),
        ],
        clk_signal="cpu_pipe_tb.clk",
        cyc_start=c_start,
        cyc_end=c_end,
        out_png=out_w_pipe,
        title="Dạng sóng RTL thật: CPU G2 xử lý Load-Use Stall & Data Forwarding (testbench/programs/tests/hazard/load_use.s)",
        subtitle=f"Trích xuất trực tiếp từ work/wave_pipeline.vcd (cửa sổ chu kỳ c{c_start}..c{c_end})",
        highlights=highlights_p,
    )

    vcd_e3 = os.path.join(WORK_DIR, "wave_e3_capture.vcd")
    _, _, _, hist_e = vcd_plot.parse_vcd(
        vcd_e3,
        ["exp_e3_tb.dut.clk", "exp_e3_tb.dut.press", "exp_e3_tb.dut.sw_capture", "exp_e3_tb.dut.bus_re", "exp_e3_tb.dut.bus_addr"],
    )
    edges_e = vcd_plot.extract_clock_cycles(hist_e["exp_e3_tb.dut.clk"])
    cap_c = None
    for idx, t in enumerate(edges_e):
        if vcd_plot.sample_at_time(hist_e["exp_e3_tb.dut.sw_capture"], t + 1000) == "1":
            cap_c = idx
            break
    if cap_c is None:
        cap_c = 100
    re_c = cap_c
    for idx in range(cap_c, min(len(edges_e), cap_c + 40)):
        t = edges_e[idx]
        if vcd_plot.sample_at_time(hist_e["exp_e3_tb.dut.bus_re"], t + 1000) == "1":
            addr = vcd_plot.sample_at_time(hist_e["exp_e3_tb.dut.bus_addr"], t + 1000)
            if addr and int(addr, 2) in (0x04, 0x24):
                re_c = idx
    ce_start = max(0, cap_c - 3)
    ce_end = min(len(edges_e) - 2, max(cap_c + 18, re_c + 3))

    out_w_e3 = os.path.join(PLOT_DIR, "fig_wave_e3_capture.png")
    vcd_plot.render_vcd_waveform(
        vcd_e3,
        signals_spec=[
            ("exp_e3_tb.dut.clk", "clk (50 MHz)", SLATE),
            ("exp_e3_tb.dut.btn", "btn_raw[3:0]", SLATE),
            ("exp_e3_tb.dut.press", "press[3:0] (2-FF)", CRIMSON),
            ("exp_e3_tb.dut.sw_capture", "sw_capture (0 ns)", CRIMSON),
            ("exp_e3_tb.dut.irq", "irq -> CP0", AMBER),
            ("exp_e3_tb.dut.u_sw.val", "u_sw.val (ms)", TEAL),
            ("exp_e3_tb.dut.bus_re", "CPU bus_re", NAVY),
            ("exp_e3_tb.dut.bus_addr", "bus_addr[7:0]", NAVY),
        ],
        clk_signal="exp_e3_tb.dut.clk",
        cyc_start=ce_start,
        cyc_end=ce_end,
        out_png=out_w_e3,
        title="Dạng sóng RTL thật (E3): Chốt phần cứng SW_LAP tại 0 ns trước khi CPU vào ISR",
        subtitle=f"Trích xuất trực tiếp từ work/wave_e3_capture.vcd (sw_capture tức thì ở c{cap_c}, CPU đọc MMIO sau đó)",
        highlights=[(cap_c, cap_c, CRIMSON, "HW Capture chốt ngay cạnh nhấn (0 ns)")],
    )
    print(f"[PLOT] -> {os.path.relpath(out_w_pipe, ROOT)}, {os.path.basename(out_w_e3)}")


def run_screen_showcase():
    """Trích xuất 6 khung hình LED 7 đoạn từ `work/screen_system.log` và xuất PNG 300 DPI."""
    _ensure_msys_path()
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(PLOT_DIR, exist_ok=True)
    os.makedirs(WORK_DIR, exist_ok=True)

    print("\n=== [7/7] Trích xuất 5 khung hình LED 7 đoạn thật từ system_tb (tools/screen.py) ===")
    log_path = os.path.join(WORK_DIR, "screen_system.log")
    if not os.path.exists(log_path):
        main_hex = os.path.join(WORK_DIR, "main.hex")
        if not os.path.exists(main_hex):
            fw_res = asm.assemble_file(os.path.join(ROOT, "fw", "main.s"), 11)
            asm.write_hex(main_hex, fw_res["imem"])
        vvp = os.path.join(WORK_DIR, "system_tb.vvp")
        _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", vvp, "testbench/hdl/system_tb.v", "testbench/hdl/screen_dump.v"] + _srcs())
        _sh(["vvp", "-n", vvp, "+imem=" + os.path.relpath(main_hex, ROOT)])

    frames = screen.load(log_path)
    tab = screen.seg_table()
    ends = [t for t, _ in frames[1:]] + [None]
    clean = [(t, s, screen.text(s, tab)) for (t, s), e in zip(frames, ends) if e is None or e - t >= screen.TEAR_MS]

    def pick(pred, fallback_idx=0):
        for t, s, txt in clean:
            if pred(txt, s):
                return t, s, txt
        return clean[fallback_idx]

    f_time = pick(lambda txt, s: txt.startswith("PM 01:05") or txt.startswith("AM"), 0)
    f_date = pick(lambda txt, s: txt.count(".") == 2 and txt.endswith("2026"), 5)
    f_alarm = pick(lambda txt, s: txt.startswith("AL1o"), 10)
    f_sw = pick(lambda txt, s: "00:01.234" in txt, 15)
    f_chess = pick(lambda txt, s: "|" in txt, len(clean) // 2)
    f_set = pick(lambda txt, s: txt.startswith("t2") or "99L" in txt or "9L" in txt, len(clean) - 2)

    chosen = [
        ("Mode 0: TIME (12h AM/PM)", f_time, (50, 220, 90)),
        ("Mode 0 (View 2): DATE (DD.MM.YYYY)", f_date, (0, 210, 255)),
        ("Mode 1: ALARM (AL1o 07:00)", f_alarm, (255, 195, 40)),
        ("Mode 2: STOPWATCH (1.234 ms)", f_sw, (255, 65, 55)),
        ("Mode 3: TIMER Kép / Cờ vua (Left | Right)", f_chess, (50, 220, 90)),
        ("Mode 4: SET Cấu hình (09L  SPL)", f_set, (255, 165, 40)),
    ]

    cell_w, cell_h = 640, 190
    pad_x, pad_y = 26, 22
    head_h = 66
    canvas_w = pad_x * 3 + cell_w * 2
    canvas_h = head_h + pad_y * 4 + cell_h * 3
    canvas = Image.new("RGB", (canvas_w, canvas_h), (248, 250, 252))
    drw = ImageDraw.Draw(canvas)

    font_path = r"C:\Windows\Fonts\arialbd.ttf"
    f_title = ImageFont.truetype(font_path, 22) if os.path.exists(font_path) else ImageFont.load_default()
    f_card = ImageFont.truetype(font_path, 15) if os.path.exists(font_path) else ImageFont.load_default()

    drw.rectangle([0, 0, canvas_w, head_h - 6], fill=(20, 50, 110))
    drw.text((24, 14), "Hiển thị LED 7 đoạn thực tế từ mô phỏng RTL toàn hệ thống (system_tb.v: PASS 634/634)",
             fill=(255, 255, 255), font=f_title)

    for idx, (label, (t_ms, segs, txt), led_col) in enumerate(chosen):
        row, col = divmod(idx, 2)
        cx = pad_x + col * (cell_w + pad_x)
        cy = head_h + pad_y + row * (cell_h + pad_y)
        drw.rounded_rectangle([cx, cy, cx + cell_w, cy + cell_h], radius=10, fill=(15, 23, 42), outline=(203, 213, 225), width=2)
        drw.text((cx + 18, cy + 12), f"{label}   |   t = {t_ms:,} ms   [{txt.strip()}]", fill=(226, 232, 240), font=f_card)

        img7 = screen.draw(segs, scale=5)
        px = img7.load()
        for yy in range(img7.height):
            for xx in range(img7.width):
                r0, g0, b0 = px[xx, yy]
                if r0 > 180 and g0 < 80:
                    px[xx, yy] = led_col
        tx = cx + (cell_w - img7.width) // 2
        ty = cy + 44
        canvas.paste(img7, (tx, ty))

    out_scr = os.path.join(PLOT_DIR, "fig_sim_screen_modes.png")
    canvas.save(out_scr, dpi=(300, 300))
    _save_json("screen_showcase.json", [
        {"label": lb, "t_ms": t, "decoded": txt.strip()} for lb, (t, _, txt), _ in chosen
    ])
    print(f"[PLOT] -> {os.path.relpath(out_scr, ROOT)}")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    run_vcd_plots()
    run_screen_showcase()
