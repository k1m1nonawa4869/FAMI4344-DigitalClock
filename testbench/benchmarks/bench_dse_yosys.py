# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    testbench/benchmarks/bench_dse_yosys.py — Benchmark DSE fmt.s & Yosys 0.66
# CHUYÊN ĐỀ KTMT: Chương 01 & 02: Không gian thiết kế phần cứng/phần mềm & Tổng hợp FPGA
# VAI TRÒ:        Đo chu kỳ fmt_bench_tb trên 4 phương án và tổng hợp tài nguyên Yosys 0.66.
# ============================================================================
"""Benchmark 2/7: DSE định dạng 8 chữ số LED (`fmt.s`) và tổng hợp Yosys 0.66."""

import os
import re
import sys

import matplotlib.pyplot as plt
import numpy as np

from common import (
    AMBER, CRIMSON, DATA_DIR, GRID, NAVY, PLOT_DIR, ROOT, SLATE, TEAL, WORK_DIR,
    _ensure_msys_path, _save_json, _sh, _srcs, _style_ax,
)
import asm  # noqa: E402
import dse_report  # noqa: E402


def run_dse_and_yosys():
    """Chạy benchmark DSE `fmt.s` + Yosys `synth_xilinx` và xuất 2 biểu đồ PNG."""
    print("\n=== [2/7] Chạy Benchmark DSE fmt.s & Tổng hợp FPGA Yosys thật ===")
    _ensure_msys_path()
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(PLOT_DIR, exist_ok=True)
    os.makedirs(WORK_DIR, exist_ok=True)

    fmt_hex = os.path.join(WORK_DIR, "fmt_bench.hex")
    res = asm.assemble_file(os.path.join(ROOT, "fw", "fmt.s"), 11)
    asm.write_hex(fmt_hex, res["imem"])

    vvp_seq = os.path.join(WORK_DIR, "fmt_bench_seq.vvp")
    vvp_comb = os.path.join(WORK_DIR, "fmt_bench_comb.vvp")
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", vvp_seq, "testbench/hdl/fmt_bench_tb.v"] + _srcs())
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-DBCD_COMB", "-o", vvp_comb, "testbench/hdl/fmt_bench_tb.v"] + _srcs())

    out_seq = _sh(["vvp", "-n", vvp_seq, "+imem=" + os.path.relpath(fmt_hex, ROOT)]).stdout
    out_comb = _sh(["vvp", "-n", vvp_comb, "+imem=" + os.path.relpath(fmt_hex, ROOT)]).stdout
    assert "PASS fmt_bench_tb" in out_seq and "PASS fmt_bench_tb" in out_comb

    pat = r"fmt_div\s+(\d+)\s+\d+\s+\d+\s+fmt_bcd\s+(\d+)\s+\d+\s+\d+\s+fmt_hw\s+(\d+)"
    m_seq = re.search(pat, out_seq)
    m_comb = re.search(pat, out_comb)
    assert m_seq and m_comb, f"Không parse được fmt_bench_tb:\n{out_seq}\n{out_comb}"

    # fmt_bench_tb chạy ở D=2 nên số chu kỳ hệ thống / 2 = số chu kỳ CPU
    c_div = int(m_seq.group(1)) // 2
    c_bcd_seq = int(m_seq.group(2)) // 2
    c_bcd_comb = int(m_comb.group(2)) // 2
    c_hw = int(m_seq.group(3)) // 2

    main_hex = os.path.join(WORK_DIR, "main.hex")
    if not os.path.exists(main_hex):
        fw_res = asm.assemble_file(os.path.join(ROOT, "fw", "main.s"), 11)
        asm.write_hex(main_hex, fw_res["imem"])

    latest_src_m = max(os.path.getmtime(p) for p in _srcs())
    yosys_table = {}
    for name, desc, top, params, define in dse_report.BLOCKS:
        stat_path = os.path.join(WORK_DIR, f"dse_{name}.log.stat")
        if os.path.exists(stat_path) and os.path.getmtime(stat_path) >= latest_src_m:
            print(f"  Yosys cache (.stat): {name}", flush=True)
            counts = dse_report.count(open(stat_path, encoding="utf-8", errors="replace").read())
        else:
            print(f"  Yosys synth: {name}...", flush=True)
            counts = dse_report.synth(name, top, params, define)
        yosys_table[name] = {"desc": desc, **counts}

    lut_base = yosys_table["soc_g1"]["LUT"]
    lut_bcdc = yosys_table["soc_g1_bcdc"]["LUT"] - lut_base
    lut_rtcb = yosys_table["soc_g1_rtcb"]["LUT"] - lut_base

    budget_cyc_per_ms = 32768.0 / 1000.0
    methods = [
        {"name": "1. Chia phần mềm (div)", "cycles": c_div, "added_lut": 0, "load_pct": round(100 * c_div / budget_cyc_per_ms, 1)},
        {"name": "2. Lệnh bcd tuần tự", "cycles": c_bcd_seq, "added_lut": 0, "load_pct": round(100 * c_bcd_seq / budget_cyc_per_ms, 1)},
        {"name": "3. Lệnh bcd tổ hợp", "cycles": c_bcd_comb, "added_lut": lut_bcdc, "load_pct": round(100 * c_bcd_comb / budget_cyc_per_ms, 1)},
        {"name": "4. Thanh ghi HW RTC_BCD", "cycles": c_hw, "added_lut": lut_rtcb, "load_pct": round(100 * c_hw / budget_cyc_per_ms, 1)},
    ]

    _save_json("dse_fmt.json", {"budget_32khz_cyc_per_ms": budget_cyc_per_ms, "methods": methods})
    _save_json("yosys_dse.json", yosys_table)

    # --- Plot 4: fig_dse_fmt.png ---
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11.2, 4.2), dpi=300)
    _style_ax(ax1)
    names = [m["name"] for m in reversed(methods)]
    cycs = [m["cycles"] for m in reversed(methods)]
    loads = [m["load_pct"] for m in reversed(methods)]
    bar_cols = [TEAL if c <= budget_cyc_per_ms else CRIMSON for c in cycs]
    bars = ax1.barh(names, cycs, height=0.52, color=bar_cols, zorder=3)
    ax1.axvline(budget_cyc_per_ms, color=NAVY, ls="--", lw=1.4, zorder=4, label="Ngưỡng 100% tải @ 32,77 kHz (32,8 cyc)")
    for b, c, l in zip(bars, cycs, loads):
        tx = max(c, budget_cyc_per_ms) + 5.5
        ax1.text(tx, b.get_y() + b.get_height() / 2, f"{c} cyc ({l:.0f}% tải)",
                 va="center", ha="left", fontsize=8.2, fontweight="bold", color=TEAL if c <= budget_cyc_per_ms else CRIMSON)
    ax1.set_xlim(0, max(cycs) * 1.38)
    ax1.set_xlabel("Số chu kỳ CPU cho 1 lần định dạng fmt.s", fontsize=9, color=SLATE)
    ax1.set_title("(a) Chi phí chu kỳ & Tải CPU ở 32,768 kHz", loc="left", fontsize=10, fontweight="bold", color=NAVY)
    ax1.legend(loc="lower right", fontsize=7.8, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)

    _style_ax(ax2)
    luts = [m["added_lut"] for m in methods]
    cycs_f = [m["cycles"] for m in methods]
    sc_cols = [CRIMSON, AMBER, NAVY, TEAL]
    for m, col in zip(methods, sc_cols):
        ax2.scatter(m["added_lut"], m["cycles"], s=110, color=col, edgecolor="#FFFFFF", lw=1.8, zorder=4)
        dx, ha = (12, "left") if m["added_lut"] < 200 else (-12, "right")
        dy = 4
        if "tuần tự" in m["name"]:
            dy = -6
        elif "RTC_BCD" in m["name"]:
            dy = -14
        ax2.annotate(f"{m['name'].split('. ')[1]}\n({m['added_lut']:+d} LUT, {m['cycles']} cyc)",
                     (m["added_lut"], m["cycles"]), xytext=(dx, dy), textcoords="offset points",
                     ha=ha, va="center", fontsize=8, fontweight="bold", color=col)
    ax2.axhline(budget_cyc_per_ms, color=NAVY, ls="--", lw=1.1, alpha=0.8)
    ax2.set_xlim(-45, max(luts) + 85)
    ax2.set_ylim(0, max(cycs_f) * 1.18)
    ax2.set_xlabel("LUT tăng thêm so với soc_g1 (Yosys synth_xilinx)", fontsize=9, color=SLATE)
    ax2.set_ylabel("Chu kỳ CPU / lần cập nhật", fontsize=9, color=SLATE)
    ax2.set_title("(b) Không gian đánh đổi LUT vs Chu kỳ (Pareto)", loc="left", fontsize=10, fontweight="bold", color=NAVY)
    fig.suptitle("Khảo sát Không gian Thiết kế (DSE): Định dạng 8 chữ số LED 7 đoạn (fmt_bench_tb + Yosys 0.66)",
                 fontsize=10.8, fontweight="bold", color=NAVY, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    out_dse = os.path.join(PLOT_DIR, "fig_dse_fmt.png")
    fig.savefig(out_dse, dpi=300)
    plt.close(fig)

    # --- Plot 5: fig_yosys_resources.png ---
    sel_keys = ["cpu_g1", "cpu_g2", "soc_g1", "soc_g2", "uart", "display", "muldiv", "alu"]
    s_luts = [yosys_table[k]["LUT"] for k in sel_keys]
    s_ffs = [yosys_table[k]["FF"] for k in sel_keys]
    fig, ax = plt.subplots(figsize=(10.2, 4.1), dpi=300)
    _style_ax(ax)
    x = np.arange(len(sel_keys))
    w = 0.38
    b1 = ax.bar(x - w / 2, s_luts, width=w, color=NAVY, label="6-Input LUT (Xilinx 7-Series)", zorder=3)
    b2 = ax.bar(x + w / 2, s_ffs, width=w, color=TEAL, label="Flip-Flop (FDRE/FDSE)", zorder=3)
    for rect in list(b1) + list(b2):
        h = rect.get_height()
        if h > 0:
            ax.text(rect.get_x() + rect.get_width() / 2, h + 45, f"{h:,}", ha="center", va="bottom",
                    fontsize=7.3, fontweight="bold", color="#0F172A")
    ax.set_xticks(x)
    ax.set_xticklabels(sel_keys, fontsize=8.8, fontweight="bold")
    ax.set_ylim(0, max(s_luts) * 1.18)
    ax.set_ylabel("Số phần tử logic (Yosys 0.66 synth_xilinx)", fontsize=9, color=SLATE)
    ax.set_title("Ước lượng tài nguyên FPGA tổng hợp trực tiếp bằng Yosys 0.66 cho lõi CPU & SoC WatchChip",
                 loc="left", fontsize=10.3, fontweight="bold", color=NAVY)
    ax.legend(loc="upper right", fontsize=8.5, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)
    fig.tight_layout()
    out_yos = os.path.join(PLOT_DIR, "fig_yosys_resources.png")
    fig.savefig(out_yos, dpi=300)
    plt.close(fig)
    print(f"[PLOT] -> {os.path.relpath(out_dse, ROOT)}, {os.path.basename(out_yos)}")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    run_dse_and_yosys()
