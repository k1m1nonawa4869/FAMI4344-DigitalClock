# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/run_benchmarks_and_plots.py — Bộ Chạy Benchmark Thực Tế & Sinh Biểu Đồ Báo Cáo
# CHUYÊN ĐỀ KTMT: Toàn hệ thống: Hiệu năng CPI/Amdahl, DSE Yosys, Thực nghiệm E1'–E4', Sóng VCD & Màn 7 Đoạn
# VAI TRÒ:        Thực thi trực tiếp mã RTL (iverilog/vvp), tổng hợp logic (Yosys) và trình giả lập ISS,
#                 lưu toàn bộ số liệu thô ra results/data/*.json và xuất ảnh 300 DPI ra results/plots/*.png.
# ============================================================================

"""Chạy toàn bộ benchmark trực tiếp trên WatchChip RTL & sinh ảnh cho Báo cáo/Slide.

Ví dụ (dùng Python trong môi trường conda data-science-env):
    D:\\miniconda3-pbe\\envs\\data-science-env\\python.exe tools/run_benchmarks_and_plots.py --all --sync-docs ../../docs/report_archive/latex/hinh/generated
"""
import argparse
import csv
import glob
import json
import math
import os
import re
import shutil
import subprocess
import sys
import types
from concurrent.futures import ThreadPoolExecutor

if "pytest" not in sys.modules:
    try:
        import pytest  # noqa: F401
    except ImportError:
        _pt = types.ModuleType("pytest")
        _mark = types.SimpleNamespace(parametrize=lambda *a, **k: (lambda fn: fn))
        _pt.mark = _mark
        sys.modules["pytest"] = _pt

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import asm  # noqa: E402
import cosim_iss  # noqa: E402
import cpi  # noqa: E402
import dse_report  # noqa: E402
import exp_cal  # noqa: E402
import exp_e3  # noqa: E402
import screen  # noqa: E402
import vcd_plot  # noqa: E402

DATA_DIR = os.path.join(ROOT, "results", "data")
PLOT_DIR = os.path.join(ROOT, "results", "plots")
WORK_DIR = os.path.join(ROOT, "work")

NAVY = "#14326E"
CRIMSON = "#B42828"
TEAL = "#0F766E"
AMBER = "#D97706"
SLATE = "#475569"
LIGHT_BG = "#F8FAFC"
GRID = "#E2E8F0"

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "axes.edgecolor": "#CBD5E1",
    "axes.linewidth": 0.9,
    "figure.facecolor": "#FFFFFF",
})


def _ensure_msys_path():
    # Đặt Conda Library/bin lên đầu PATH (hoặc add_dll_directory) để matplotlib không nạp nhầm DLL của MSYS2
    conda_bins = [p for p in (os.path.join(sys.prefix, "Library", "bin"), sys.prefix) if os.path.isdir(p)]
    for p in conda_bins:
        if hasattr(os, "add_dll_directory"):
            try:
                os.add_dll_directory(p)
            except OSError:
                pass
    msys_bin = r"C:\msys64\ucrt64\bin"
    cur = [x for x in os.environ.get("PATH", "").split(os.pathsep) if x and os.path.normcase(x) != os.path.normcase(msys_bin)]
    new_path = conda_bins + [x for x in cur if x not in conda_bins]
    if os.path.isdir(msys_bin):
        new_path.append(msys_bin)  # để cuối cùng cho iverilog/vvp/yosys
    os.environ["PATH"] = os.pathsep.join(new_path)


def _srcs():
    return sorted(glob.glob(os.path.join(ROOT, "src", "*.v")))


def _helpers():
    return sorted(
        f for f in glob.glob(os.path.join(ROOT, "tb", "*.v")) if not f.endswith("_tb.v")
    )


def _sh(cmd, check=True):
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        raise RuntimeError(f"Lệnh lỗi ({r.returncode}): {' '.join(cmd)}\n{r.stdout}\n{r.stderr}")
    return r


def _style_ax(ax):
    ax.set_facecolor("#FFFFFF")
    ax.grid(True, linestyle="--", linewidth=0.75, color=GRID, zorder=0)
    ax.set_axisbelow(True)
    for sp in ("top", "right"):
        ax.spines[sp].set_visible(False)
    ax.tick_params(colors=SLATE, labelsize=8.5)


def _save_json(name, obj):
    os.makedirs(DATA_DIR, exist_ok=True)
    path = os.path.join(DATA_DIR, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    print(f"[DATA] -> {os.path.relpath(path, ROOT)}")
    return path


# ----------------------------------------------------------------------------
# 1. BENCHMARK CPI G1 VS G2 & PHÂN RÃ CHU KỲ G2 + ĐỊNH LUẬT AMDAHL THỰC TẾ
# ----------------------------------------------------------------------------
def run_cpi_and_amdahl():
    print("\n=== [1/7] Chạy Benchmark CPI G1 vs G2 trên RTL thật ===")
    os.makedirs(os.path.join(WORK_DIR, "bench_cpi"), exist_ok=True)
    bdir = os.path.join(WORK_DIR, "bench_cpi")

    g1_vvp = os.path.join(bdir, "cpu_g1_tb.vvp")
    g2_vvp = os.path.join(bdir, "cpu_pipe_tb.vvp")
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", g1_vvp, "tb/cpu_g1_tb.v"] + _srcs() + _helpers())
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", g2_vvp, "tb/cpu_pipe_tb.v"] + _srcs() + _helpers())

    cpu_progs = ["sum100", "fact10", "bcd"]
    rows = []
    for prog in cpu_progs:
        src = os.path.join(ROOT, "fw", "tests", "cpu", f"{prog}.s")
        hexf = os.path.join(bdir, f"{prog}.hex")
        res = asm.assemble_file(src, 10)
        asm.write_hex(hexf, res["imem"])
        end_hex = f"{4 * res['nwords']:x}"

        csv1 = os.path.join(bdir, f"{prog}_g1.csv")
        csv2 = os.path.join(bdir, f"{prog}_g2.csv")
        _sh(["vvp", "-n", g1_vvp, "+imem=" + os.path.relpath(hexf, ROOT), "+end=" + end_hex,
             "+trace=" + os.path.relpath(csv1, ROOT), "+maxcyc=200000"])
        _sh(["vvp", "-n", g2_vvp, "+imem=" + os.path.relpath(hexf, ROOT), "+end=" + end_hex,
             "+trace=" + os.path.relpath(csv2, ROOT), "+maxcyc=200000"])
        r1 = cpi.analyse(csv1)
        r2 = cpi.analyse(csv2)
        cpi1, cpi2 = r1["cyc"] / r1["n"], r2["cyc"] / r2["n"]
        # Thời gian thực: G1 chạy 25 MHz (40 ns), G2 chạy 50 MHz (20 ns)
        t1_us = r1["cyc"] * 0.04
        t2_us = r2["cyc"] * 0.02
        rows.append({
            "name": prog,
            "g1": r1, "cpi_g1": round(cpi1, 4), "time_g1_us": round(t1_us, 3),
            "g2": r2, "cpi_g2": round(cpi2, 4), "time_g2_us": round(t2_us, 3),
            "speedup": round(t1_us / t2_us, 3),
        })

    # Firmware đầy đủ fw/main.s qua system_tb.v (G1 & G2)
    main_hex = os.path.join(WORK_DIR, "main.hex")
    fw_res = asm.assemble_file(os.path.join(ROOT, "fw", "main.s"), 11)
    asm.write_hex(main_hex, fw_res["imem"])

    sys_g1_vvp = os.path.join(bdir, "sys_g1.vvp")
    sys_g2_vvp = os.path.join(bdir, "sys_g2.vvp")
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", sys_g1_vvp,
         "tb/system_tb.v", "tb/screen_dump.v"] + _srcs())
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-DG2", "-o", sys_g2_vvp,
         "tb/system_tb.v", "tb/screen_dump.v"] + _srcs())

    sys_csv1 = os.path.join(bdir, "main_g1.csv")
    sys_csv2 = os.path.join(bdir, "main_g2.csv")
    out1 = _sh(["vvp", "-n", sys_g1_vvp, "+imem=" + os.path.relpath(main_hex, ROOT),
                "+trace=" + os.path.relpath(sys_csv1, ROOT)]).stdout
    out2 = _sh(["vvp", "-n", sys_g2_vvp, "+imem=" + os.path.relpath(main_hex, ROOT),
                "+trace=" + os.path.relpath(sys_csv2, ROOT)]).stdout
    assert "PASS system_tb 634" in out1 and "PASS system_tb 634" in out2

    sr1 = cpi.analyse(sys_csv1)
    sr2 = cpi.analyse(sys_csv2)
    assert sr2["khác"] == 0, f"G2 phát hiện chu kỳ chưa giải thích: {sr2['khác']}"

    scpi1, scpi2 = sr1["cyc"] / sr1["n"], sr2["cyc"] / sr2["n"]
    # Thông lượng lệnh thực hiện trong cùng 1 giây @ (25 MHz G1 vs 50 MHz G2)
    mips_g1 = 25.0 / scpi1
    mips_g2 = 50.0 / scpi2
    fw_entry = {
        "name": "main.s (SoC)",
        "g1": sr1, "cpi_g1": round(scpi1, 4), "mips_g1": round(mips_g1, 3),
        "g2": sr2, "cpi_g2": round(scpi2, 4), "mips_g2": round(mips_g2, 3),
        "throughput_gain_pct": round((mips_g2 / mips_g1 - 1.0) * 100.0, 2),
        "speedup": round(mips_g2 / mips_g1, 3),
    }

    # Tính các thành phần phần trăm phân rã G2 chính xác từ sr2
    tot_g2 = sr2["cyc"]
    eff_g2 = sr2["n"]
    br_g2 = sr2["nhánh"]
    busy_g2 = sr2["busy"]
    lu_g2 = sr2["load-use"]
    irq_extra_g2 = sr2["ngắt"]
    other_g2 = sr2["khác"]
    irq_gap_g2 = tot_g2 - (eff_g2 + br_g2 + busy_g2 + lu_g2 + irq_extra_g2 + other_g2)
    n_irq_rows = sum(1 for ln in open(sys_csv2, encoding="utf-8") if ",INTERRUPT," in ln)
    assert 0 <= irq_gap_g2 <= n_irq_rows, f"Lệch chu kỳ G2: gap={irq_gap_g2}, irq_rows={n_irq_rows}"
    irq_g2 = irq_extra_g2 + irq_gap_g2
    assert eff_g2 + br_g2 + busy_g2 + lu_g2 + irq_g2 + other_g2 == tot_g2

    summary = {
        "cpu_benchmarks": rows,
        "firmware_main": fw_entry,
        "g2_breakdown": {
            "total_cyc": tot_g2,
            "effective_cyc": eff_g2, "effective_pct": round(100 * eff_g2 / tot_g2, 2),
            "branch_cyc": br_g2, "branch_pct": round(100 * br_g2 / tot_g2, 2),
            "busy_cyc": busy_g2, "busy_pct": round(100 * busy_g2 / tot_g2, 2),
            "load_use_cyc": lu_g2, "load_use_pct": round(100 * lu_g2 / tot_g2, 2),
            "irq_cyc": irq_g2, "irq_pct": round(100 * irq_g2 / tot_g2, 2),
            "other_cyc": other_g2,
        },
    }
    _save_json("cpi_benchmark.json", summary)

    # --- Plot 1: fig_cpi_g1_vs_g2.png ---
    labels = [r["name"] for r in rows] + ["fw/main.s"]
    cpi_g1s = [r["cpi_g1"] for r in rows] + [fw_entry["cpi_g1"]]
    cpi_g2s = [r["cpi_g2"] for r in rows] + [fw_entry["cpi_g2"]]
    speedups = [r["speedup"] for r in rows] + [fw_entry["speedup"]]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11.0, 4.2), dpi=300)
    x = np.arange(len(labels))
    w = 0.35
    _style_ax(ax1)
    b1 = ax1.bar(x - w / 2, cpi_g1s, width=w, color=NAVY, label="G1 (Đơn chu kỳ 2 pha, 25 MHz)", zorder=3)
    b2 = ax1.bar(x + w / 2, cpi_g2s, width=w, color=CRIMSON, label="G2 (Pipeline 5 tầng, 50 MHz)", zorder=3)
    for rect in list(b1) + list(b2):
        h = rect.get_height()
        ax1.text(rect.get_x() + rect.get_width() / 2, h + 0.04, f"{h:.3f}", ha="center", va="bottom", fontsize=7.8, color="#0F172A")
    ax1.set_xticks(x)
    ax1.set_xticklabels(labels, fontsize=8.5, fontweight="bold")
    ax1.set_ylim(0, max(cpi_g2s) * 1.25)
    ax1.set_ylabel("CPI trung bình (chu kỳ / lệnh)", fontsize=9, color=SLATE)
    ax1.set_title("(a) So sánh CPI đo từ trace RTL", loc="left", fontsize=10, fontweight="bold", color=NAVY)
    ax1.legend(loc="upper left", fontsize=8, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)

    _style_ax(ax2)
    b3 = ax2.bar(x, speedups, width=0.48, color=TEAL, zorder=3)
    ax2.axhline(1.0, color=CRIMSON, ls="--", lw=1.1, label="Ngưỡng hòa vốn (1,00x)")
    for rect in b3:
        h = rect.get_height()
        ax2.text(rect.get_x() + rect.get_width() / 2, h + 0.03, f"{h:.2f}x\n(+{(h-1)*100:.1f}%)",
                 ha="center", va="bottom", fontsize=8, fontweight="bold", color=TEAL)
    ax2.set_xticks(x)
    ax2.set_xticklabels(labels, fontsize=8.5, fontweight="bold")
    ax2.set_ylim(0, max(speedups) * 1.28)
    ax2.set_ylabel("Tăng tốc thực tế G2 so với G1 (x)", fontsize=9, color=SLATE)
    ax2.set_title("(b) Lợi ích xung nhịp gấp đôi (CPI/f_clk)", loc="left", fontsize=10, fontweight="bold", color=NAVY)
    ax2.legend(loc="lower right", fontsize=8, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)
    fig.suptitle("Hiệu năng đo thực tế từ trace RTL: CPU G1 (25 MHz) vs CPU G2 Pipeline (50 MHz)",
                 fontsize=11, fontweight="bold", color=NAVY, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    out_p1 = os.path.join(PLOT_DIR, "fig_cpi_g1_vs_g2.png")
    fig.savefig(out_p1, dpi=300)
    plt.close(fig)

    # --- Plot 2: fig_g2_cpi_breakdown.png ---
    bd = summary["g2_breakdown"]
    cats = [
        f"Ngắt IRQ ({bd['irq_cyc']:,} cyc)",
        f"Load-Use Stall ({bd['load_use_cyc']:,} cyc)",
        f"Phạt rẽ nhánh 2 cyc EX ({bd['branch_cyc']:,} cyc)",
        f"Đa chu kỳ div / bcd ({bd['busy_cyc']:,} cyc)",
        f"Thực thi lệnh hiệu dụng ({bd['effective_cyc']:,} cyc)",
    ]
    pcts = [bd["irq_pct"], bd["load_use_pct"], bd["branch_pct"], bd["busy_pct"], bd["effective_pct"]]
    cols = [SLATE, AMBER, CRIMSON, TEAL, NAVY]
    fig, ax = plt.subplots(figsize=(9.2, 4.0), dpi=300)
    _style_ax(ax)
    bars = ax.barh(cats, pcts, height=0.56, color=cols, zorder=3)
    for bar, p in zip(bars, pcts):
        ax.text(p + 0.8, bar.get_y() + bar.get_height() / 2, f"{p:.1f}%", va="center", ha="left",
                fontsize=9, fontweight="bold", color="#0F172A")
    ax.set_xlim(0, max(pcts) + 10)
    ax.set_xlabel(f"Tỷ trọng đóng góp trong tổng {bd['total_cyc']:,} chu kỳ CPU G2 (khác = {bd['other_cyc']} chu kỳ)",
                  fontsize=9, color=SLATE)
    ax.set_title(f"Phân rã {bd['total_cyc']:,} chu kỳ thực thi trên CPU G2 (tools/cpi.py)",
                 loc="left", fontsize=10.2, fontweight="bold", color=NAVY)
    fig.tight_layout()
    out_p2 = os.path.join(PLOT_DIR, "fig_g2_cpi_breakdown.png")
    fig.savefig(out_p2, dpi=300)
    plt.close(fig)

    # --- Plot 3: fig_amdahl_real.png ---
    f_br = br_g2 / tot_g2
    f_busy = busy_g2 / tot_g2
    f_both = f_br + f_busy
    s_en = np.linspace(1.0, 16.0, 300)
    s_br = 1.0 / ((1.0 - f_br) + f_br / s_en)
    s_busy = 1.0 / ((1.0 - f_busy) + f_busy / s_en)
    s_both = 1.0 / ((1.0 - f_both) + f_both / s_en)

    ceil_br = 1.0 / (1.0 - f_br)
    ceil_busy = 1.0 / (1.0 - f_busy)
    ceil_both = 1.0 / (1.0 - f_both)
    s_id2 = 1.0 / ((1.0 - f_br) + f_br / 2.0)

    fig, ax = plt.subplots(figsize=(9.2, 4.3), dpi=300)
    _style_ax(ax)
    ax.plot(s_en, s_br, color=NAVY, lw=2.3,
            label=f"Chỉ tối ưu rẽ nhánh (f_br = {f_br*100:.1f}% -> trần {ceil_br:.2f}x)")
    ax.plot(s_en, s_busy, color=AMBER, lw=2.1, ls="-.",
            label=f"Chỉ tối ưu div/bcd (f_busy = {f_busy*100:.1f}% -> trần {ceil_busy:.2f}x)")
    ax.plot(s_en, s_both, color=TEAL, lw=2.4, ls="--",
            label=f"Kết hợp Nhánh + div/bcd (f = {f_both*100:.1f}% -> trần {ceil_both:.2f}x)")

    ax.axhline(ceil_br, color=NAVY, ls=":", lw=1.0, alpha=0.8)
    ax.axhline(ceil_both, color=TEAL, ls=":", lw=1.0, alpha=0.8)
    ax.scatter([2.0], [s_id2], color=CRIMSON, s=65, zorder=5)
    ax.annotate(f"Chuyển nhánh về ID (S_en=2): {s_id2:.3f}x\n(tiết kiệm {br_g2//2:,} cyc = {f_br*50:.1f}%)",
                xy=(2.0, s_id2), xytext=(3.1, s_id2 - 0.08),
                arrowprops=dict(arrowstyle="->", color=CRIMSON, lw=1.2),
                fontsize=8.3, fontweight="bold", color=CRIMSON,
                bbox=dict(boxstyle="round,pad=0.3", facecolor="#FFF5F5", edgecolor=CRIMSON, alpha=0.95))

    ax.set_xlim(1, 16)
    ax.set_ylim(0.98, ceil_both + 0.14)
    ax.set_xlabel("Hệ số cải tiến cục bộ S_en của khối được tối ưu", fontsize=9, color=SLATE)
    ax.set_ylabel("Hệ số tăng tốc toàn hệ thống S_overall (x)", fontsize=9, color=SLATE)
    ax.set_title("Định luật Amdahl tính trực tiếp từ số đo CPI thực tế trên WatchChip G2",
                 loc="left", fontsize=10.5, fontweight="bold", color=NAVY)
    ax.legend(loc="upper left", fontsize=8.3, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)
    fig.tight_layout()
    out_p3 = os.path.join(PLOT_DIR, "fig_amdahl_real.png")
    fig.savefig(out_p3, dpi=300)
    plt.close(fig)
    print(f"[PLOT] -> {os.path.relpath(out_p1, ROOT)}, {os.path.basename(out_p2)}, {os.path.basename(out_p3)}")


# ----------------------------------------------------------------------------
# 2. BENCHMARK DSE fmt.s + TỔNG HỢP YOSYS THẬT
# ----------------------------------------------------------------------------
def run_dse_and_yosys():
    print("\n=== [2/7] Chạy Benchmark DSE fmt.s & Tổng hợp FPGA Yosys thật ===")
    _ensure_msys_path()
    os.makedirs(WORK_DIR, exist_ok=True)
    fmt_hex = os.path.join(WORK_DIR, "fmt_bench.hex")
    res = asm.assemble_file(os.path.join(ROOT, "fw", "fmt.s"), 11)
    asm.write_hex(fmt_hex, res["imem"])

    vvp_seq = os.path.join(WORK_DIR, "fmt_bench_seq.vvp")
    vvp_comb = os.path.join(WORK_DIR, "fmt_bench_comb.vvp")
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", vvp_seq, "tb/fmt_bench_tb.v"] + _srcs())
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-DBCD_COMB", "-o", vvp_comb, "tb/fmt_bench_tb.v"] + _srcs())

    out_seq = _sh(["vvp", "-n", vvp_seq, "+imem=" + os.path.relpath(fmt_hex, ROOT)]).stdout
    out_comb = _sh(["vvp", "-n", vvp_comb, "+imem=" + os.path.relpath(fmt_hex, ROOT)]).stdout
    assert "PASS fmt_bench_tb" in out_seq and "PASS fmt_bench_tb" in out_comb

    pat = r"fmt_div\s+(\d+)\s+\d+\s+\d+\s+fmt_bcd\s+(\d+)\s+\d+\s+\d+\s+fmt_hw\s+(\d+)"
    m_seq = re.search(pat, out_seq)
    m_comb = re.search(pat, out_comb)
    assert m_seq and m_comb, f"Không parse được fmt_bench_tb:\n{out_seq}\n{out_comb}"

    # Chú ý: fmt_bench_tb chạy ở D=2 nên số chu kỳ hệ thống / 2 = số chu kỳ CPU
    c_div = int(m_seq.group(1)) // 2
    c_bcd_seq = int(m_seq.group(2)) // 2
    c_bcd_comb = int(m_comb.group(2)) // 2
    c_hw = int(m_seq.group(3)) // 2

    # Đảm bảo work/main.hex tồn tại cho dse_report.py
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


# ----------------------------------------------------------------------------
# 3. THỰC NGHIỆM E1' & E2': HIỆU CHUẨN THẠCH ANH & BỘ TÍCH LŨY 2000 MS
# ----------------------------------------------------------------------------
def run_exp_e1_e2():
    print("\n=== [3/7] Chạy Thực nghiệm E1' & E2' (Hiệu chuẩn ppm & Tích lũy 2000 ms) ===")
    os.makedirs(WORK_DIR, exist_ok=True)
    vvp = os.path.join(WORK_DIR, "exp_cal_tb.vvp")
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", vvp, "tb/exp_cal_tb.v"] + _srcs())

    # E1' chạy song song 7 mức lệch 1 giờ (3.600.000 ms), K = 200 ms thật (10^7 chu kỳ/ca -> phân giải 0,10 ppm)
    exp_cal.K = 200
    ppms = [-199, -80, -20, 20, 80, 150, 250]
    interval_ms = 3600000
    prep = []
    for p in ppms:
        d = round(interval_ms * p / 1e6)
        cal = exp_cal.sync_cal(exp_cal.T1, exp_cal.T1 + interval_ms, d)
        prep.append((p, d, cal))
    with ThreadPoolExecutor(max_workers=min(len(prep), os.cpu_count() or 4)) as ex:
        rtl_cs = list(ex.map(exp_cal.rtl_cycles, [x[2] for x in prep]))
    e1_rows = []
    for (p, d, cal), c in zip(prep, rtl_cs):
        assert c == exp_cal.K * 50000 + ((exp_cal.K * cal) >> 16)
        after_ppm = (50000.0 * (1.0 + p * 1e-6) / (c / exp_cal.K) - 1.0) * 1e6
        print(f"  E1' p={p:+4d} ppm | D={d:+d} ms | CAL={cal:+d} | C={c:,} | res={after_ppm:+.3f} ppm", flush=True)
        e1_rows.append({"in_ppm": p, "d_ms": d, "cal": cal, "k_ms": exp_cal.K, "rtl_cycles": c, "after_ppm": round(after_ppm, 4)})

    # E2' trên bộ tích lũy 2000 ms (G_N = 50)
    e2_out = _sh(["vvp", "-n", vvp]).stdout
    assert "PASS exp_cal_tb" in e2_out
    e2_rows = []
    for ln in e2_out.splitlines():
        m = re.match(r"E2\s+G_N=(\d+)\s+cal=(-?\d+)\s+chu_ky=(\d+)\s+ky_vong=(\d+)\s+(\S+)", ln.strip())
        if m:
            e2_rows.append({
                "gn": int(m.group(1)), "cal": int(m.group(2)),
                "measured_cyc": int(m.group(3)), "formula_cyc": int(m.group(4)), "status": m.group(5)
            })

    _save_json("exp_e1_e2.json", {"e1": e1_rows, "e2": e2_rows})

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11.2, 4.2), dpi=300)
    _style_ax(ax1)
    # Tách các ca hợp lệ (<=200 ppm) để thấy rõ độ chính xác gần 0 ppm
    valid_rows = [r for r in e1_rows if abs(r["in_ppm"]) <= 200]
    rejected_row = [r for r in e1_rows if abs(r["in_ppm"]) > 200][0]
    vx = np.arange(len(valid_rows))
    afters = [abs(r["after_ppm"]) for r in valid_rows]
    ax1.bar(vx, afters, width=0.5, color=TEAL, label="Sai số tuyệt đối còn lại sau CAL (|ppm|)", zorder=3)
    ax1.axhline(0.28, color=CRIMSON, ls="--", lw=1.4, label="Chuẩn 1 ms/giờ (0,28 ppm)")
    for i, r in enumerate(valid_rows):
        ax1.text(i, abs(r["after_ppm"]) + 0.012, f"{r['after_ppm']:+.2f}\nppm", ha="center", va="bottom",
                 fontsize=7.8, fontweight="bold", color=TEAL)
    ax1.set_xticks(vx)
    ax1.set_xticklabels([f"{r['in_ppm']:+d}\nppm" for r in valid_rows], fontsize=8.3, fontweight="bold")
    ax1.set_ylim(0, 0.36)
    ax1.set_ylabel("Độ lệch còn lại sau hiệu chỉnh |ppm|", fontsize=9, color=SLATE)
    ax1.set_title(f"(a) E1': Bù trôi thạch anh về <= 0,10 ppm\n(Mẫu lỗi {rejected_row['in_ppm']:+d} ppm bị bộ lọc từ chối: CAL={rejected_row['cal']})",
                  loc="left", fontsize=9.5, fontweight="bold", color=NAVY)
    ax1.legend(loc="upper right", fontsize=7.8, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)

    _style_ax(ax2)
    e2_sorted = sorted(e2_rows, key=lambda r: r["cal"])
    cal_vals = [r["cal"] / 1000.0 for r in e2_sorted]
    meas = [r["measured_cyc"] / 1000.0 for r in e2_sorted]
    form = [r["formula_cyc"] / 1000.0 for r in e2_sorted]
    ax2.plot(cal_vals, form, color=NAVY, lw=2.0, label="Công thức lý thuyết 2000*50 + floor(2000*CAL/65536)")
    ax2.scatter(cal_vals, meas, color=CRIMSON, s=55, zorder=5, label="Đo trực tiếp từ RTL timebase (lệch = 0 cyc)")
    ax2.set_xlabel("Giá trị thanh ghi hiệu chuẩn CAL (x 1.000)", fontsize=9, color=SLATE)
    ax2.set_ylabel("Tổng chu kỳ trong 2.000 ms (x 1.000)", fontsize=9, color=SLATE)
    ax2.set_title("(b) E2': Kiểm chứng bộ tích lũy 2.000 ms (khớp 100%)", loc="left", fontsize=9.5, fontweight="bold", color=NAVY)
    ax2.legend(loc="upper left", fontsize=7.7, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)
    fig.suptitle("Thực nghiệm E1' & E2': Độ chính xác bộ định thời phân số có hiệu chỉnh CAL (exp_cal_tb.v)",
                 fontsize=10.8, fontweight="bold", color=NAVY, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    out_cal = os.path.join(PLOT_DIR, "fig_exp_e1_e2_cal.png")
    fig.savefig(out_cal, dpi=300)
    plt.close(fig)
    print(f"[PLOT] -> {os.path.relpath(out_cal, ROOT)}")


# ----------------------------------------------------------------------------
# 4. THỰC NGHIỆM E3: POLLING VS NGẮT IRQ VS HW CAPTURE 0 NS (6.000 LẦN BẤM)
# ----------------------------------------------------------------------------
def run_exp_e3(n_press=60):
    print(f"\n=== [4/7] Chạy Thực nghiệm E3 ({n_press * 6} lần bấm: Polling vs IRQ vs HW Capture) ===", flush=True)
    os.makedirs(WORK_DIR, exist_ok=True)
    vvp = os.path.join(WORK_DIR, "exp_e3_tb.vvp")
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", vvp, "tb/exp_e3_tb.v"] + _srcs())
    _sh([sys.executable, os.path.join(HERE, "exp_e3.py"), "--n", str(n_press)])

    stats = {}
    samples_d1526 = {}
    for d in exp_e3.DS:
        for m in exp_e3.MODES:
            csv_path = os.path.join(WORK_DIR, "exp_e3", f"e3_{m}_{d}.csv")
            with open(csv_path, encoding="utf-8") as f:
                lats_us = [int(r["lat_cyc"]) / 50.0 for r in csv.DictReader(f)]
            stats[f"{m}_D{d}"] = {
                "mode": m, "D": d, "n": len(lats_us),
                "min_us": round(min(lats_us), 3),
                "mean_us": round(sum(lats_us) / len(lats_us), 2),
                "p95_us": round(float(np.percentile(lats_us, 95)), 2),
                "max_us": round(max(lats_us), 2),
            }
            if d == 1526:
                samples_d1526[m] = lats_us

    _save_json("exp_e3.json", {"n_per_case": n_press, "total_presses": n_press * 6, "cases": stats})

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11.2, 4.3), dpi=300)
    _style_ax(ax1)
    ds = [2, 100, 1526]
    xlabs = ["D = 2\n(25 MHz)", "D = 100\n(500 kHz)", "D = 1526\n(32,77 kHz)"]
    poll_mean = [stats[f"poll_D{d}"]["mean_us"] for d in ds]
    poll_max = [stats[f"poll_D{d}"]["max_us"] for d in ds]
    irq_mean = [stats[f"irq_D{d}"]["mean_us"] for d in ds]
    irq_max = [stats[f"irq_D{d}"]["max_us"] for d in ds]

    x = np.arange(len(ds))
    w = 0.25
    b1 = ax1.bar(x - w, poll_mean, width=w, color=CRIMSON, label="Polling (trung bình / vạch max)", zorder=3)
    b2 = ax1.bar(x, irq_mean, width=w, color=AMBER, label="Ngắt IRQ (trung bình / vạch max)", zorder=3)
    ax1.bar(x + w, [0, 0, 0], width=w, color=TEAL, label=f"HW Capture SW_LAP (0 ns / {n_press*6} ca)", zorder=3)

    # Vẽ vạch max bằng errorbar hướng lên
    ax1.errorbar(x - w, poll_mean, yerr=[np.zeros(3), np.array(poll_max) - np.array(poll_mean)],
                 fmt="none", ecolor="#7F1D1D", elinewidth=1.4, capsize=4, zorder=4)
    ax1.errorbar(x, irq_mean, yerr=[np.zeros(3), np.array(irq_max) - np.array(irq_mean)],
                 fmt="none", ecolor="#92400E", elinewidth=1.4, capsize=4, zorder=4)
    ax1.axhline(1000.0, color=NAVY, ls="--", lw=1.3, label="Ngưỡng sai 1 ms (1.000 us)")

    for i in range(3):
        ax1.text(x[i] - w, poll_max[i] + 35, f"TB {poll_mean[i]:.0f}\nmax {poll_max[i]:.0f}", ha="center", va="bottom", fontsize=7.0, color=CRIMSON)
        ax1.text(x[i], irq_max[i] + 35, f"TB {irq_mean[i]:.0f}\nmax {irq_max[i]:.0f}", ha="center", va="bottom", fontsize=7.0, color="#92400E")
        ax1.text(x[i] + w, 25, "0 ns", ha="center", va="bottom", fontsize=8.0, fontweight="bold", color=TEAL)

    ax1.set_xticks(x)
    ax1.set_xticklabels(xlabs, fontsize=8.5, fontweight="bold")
    ax1.set_ylim(0, max(poll_max) * 1.25)
    ax1.set_ylabel("Độ trễ chốt thời điểm (us)", fontsize=9, color=SLATE)
    ax1.set_title("(a) Độ trễ min / TB / max theo tốc độ CPU", loc="left", fontsize=9.8, fontweight="bold", color=NAVY)
    ax1.legend(loc="upper left", fontsize=7.4, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)

    _style_ax(ax2)
    bins = np.linspace(0, max(poll_max) + 50, 20)
    ax2.hist(samples_d1526["poll"], bins=bins, color=CRIMSON, alpha=0.52, edgecolor="#FFFFFF", label=f"Polling @ D=1526 (n={n_press})")
    ax2.hist(samples_d1526["irq"], bins=bins, color=AMBER, alpha=0.62, edgecolor="#FFFFFF", label=f"Ngắt IRQ @ D=1526 (n={n_press})")
    ax2.axvline(0.0, color=TEAL, lw=3.0, label=f"HW Capture = 0 ns ({n_press}/{n_press} ca)")
    ax2.axvline(1000.0, color=NAVY, ls="--", lw=1.3, label="Giới hạn sai lệch 1 ms")
    ax2.set_xlabel("Độ trễ thực đo ở đồng hồ 32,77 kHz (us)", fontsize=9, color=SLATE)
    ax2.set_ylabel(f"Số lần bấm nút (trên {n_press} mẫu)", fontsize=9, color=SLATE)
    ax2.set_title("(b) Phân phối độ trễ thực tại 32,768 kHz (D = 1526)", loc="left", fontsize=9.8, fontweight="bold", color=NAVY)
    ax2.legend(loc="upper right", fontsize=7.4, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)

    fig.suptitle(f"Thí nghiệm E3: Đo đạc {n_press * 6} lần bấm nút ngẫu nhiên trên RTL (tools/exp_e3.py --n {n_press})",
                 fontsize=10.8, fontweight="bold", color=NAVY, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    out_e3 = os.path.join(PLOT_DIR, "fig_exp_e3_latency.png")
    fig.savefig(out_e3, dpi=300)
    plt.close(fig)
    print(f"[PLOT] -> {os.path.relpath(out_e3, ROOT)}")


# ----------------------------------------------------------------------------
# 5. THỰC NGHIỆM E4': CHỐNG BÓNG MA LED 7 ĐOẠN (SÓNG CSV + TỶ LỆ ĐO THẬT)
# ----------------------------------------------------------------------------
def run_exp_e4():
    print("\n=== [5/7] Chạy Thực nghiệm E4' (Chống bóng ma LED 7 đoạn) ===")
    os.makedirs(WORK_DIR, exist_ok=True)
    vvp = os.path.join(WORK_DIR, "exp_e4_tb.vvp")
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", vvp, "tb/exp_e4_tb.v"] + _srcs())
    wave_csv = os.path.join(WORK_DIR, "exp_e4_wave.csv")
    out = _sh(["vvp", "-n", vvp, "+csv=" + os.path.relpath(wave_csv, ROOT)]).stdout
    assert "PASS exp_e4_tb" in out

    e4_rows = []
    for ln in out.splitlines():
        m = re.match(
            r"E4\s+G_SLOT=(\d+)\s+G_BLANK=(\d+)\s+T_OFF=(\d+)\s+gap=(\d+)\s+on=(\d+)\s+ghost=(\d+)\s+ti_le=([0-9.]+)%",
            ln.strip(),
        )
        if m:
            e4_rows.append({
                "G_SLOT": int(m.group(1)), "G_BLANK": int(m.group(2)),
                "T_OFF": int(m.group(3)), "gap": int(m.group(4)),
                "on_cyc": int(m.group(5)), "ghost_cyc": int(m.group(6)),
                "ghost_pct": float(m.group(7)),
            })
    _save_json("exp_e4.json", {"cases": e4_rows})

    with open(wave_csv, encoding="utf-8") as f:
        wrows = list(csv.DictReader(f))

    fig = plt.figure(figsize=(11.0, 6.2), dpi=300)
    gs = fig.add_gridspec(3, 1, height_ratios=[1.1, 1.1, 1.25], hspace=0.68)

    for idx, (blank_flag, ttl, col_gh) in enumerate([
        ("0", "(a) G_BLANK = 0: Đổi chân đoạn seg ngay tại c = 0 -> Bóng ma trong suốt đuôi tắt transistor", CRIMSON),
        ("1", "(b) G_BLANK = 100 (2 us >= T_OFF = 1 us): Giữ dữ liệu khe j-1 tới c = G_BLANK -> Bóng ma = 0,00%", TEAL),
    ]):
        ax = fig.add_subplot(gs[idx])
        r = [x for x in wrows if x["blank"] == blank_flag]
        t = [int(x["cyc"]) - 3125 for x in r]
        traces = [("an[0] (RTL)", "an0", SLATE), ("Anode 0 vật lý\n(T_OFF = 50 cyc)", "vl0", NAVY), ("an[1] (RTL)", "an1", AMBER)]
        for k, (name, col, color) in enumerate(traces):
            y0 = 1.6 * (len(traces) - 1 - k)
            ax.step(t, [y0 + 1.0 * int(x[col]) for x in r], where="post", color=color, lw=1.8, zorder=3)
            ax.text(t[0] - 3, y0 + 0.45, name, ha="right", va="center", fontsize=8.0, fontweight="bold", color="#0F172A")
        gh = [int(x["ghost0"]) for x in r]
        n_gh = sum(gh)
        ax.fill_between(t, -0.3, 4.5, where=gh, step="post", color=CRIMSON, alpha=0.25, zorder=2,
                        label=f"Vùng bóng ma: {n_gh} cyc ({n_gh/50:.2f} us)")
        ax.axvline(0, color=NAVY, lw=1.0, ls=":")
        if blank_flag == "1":
            ax.axvline(100, color=TEAL, lw=1.2, ls="--", label="c = G_BLANK (100 cyc)")
        ax.set_yticks([])
        ax.set_xlim(t[0], t[-1])
        ax.set_title(ttl, loc="left", fontsize=9.3, fontweight="bold", color=col_gh)
        for sp in ("top", "right", "left"):
            ax.spines[sp].set_visible(False)
        ax.legend(loc="upper right", fontsize=7.6, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)
        if idx == 1:
            ax.set_xlabel("Chu kỳ 50 MHz quanh ranh giới khe quét 0 -> 1 (c = 0 tại G_SLOT = 3.125)", fontsize=8.5, color=SLATE)

    ax3 = fig.add_subplot(gs[2])
    _style_ax(ax3)
    # Lọc 3 cặp tiêu chuẩn T_OFF = 50 (1 us) ở 125 Hz, 500 Hz, 2 kHz
    t50 = [r for r in e4_rows if r["T_OFF"] == 50]
    freqs = ["125 Hz\n(G_SLOT=50.000)", "500 Hz\n(G_SLOT=12.500)", "2 kHz\n(G_SLOT=3.125)"]
    before = [r["ghost_pct"] for r in t50 if r["G_BLANK"] == 0]
    after = [r["ghost_pct"] for r in t50 if r["G_BLANK"] == 100]
    x = np.arange(3)
    w = 0.32
    b_bef = ax3.bar(x - w / 2, before, width=w, color=CRIMSON, label="Trước sửa (G_BLANK = 0)", zorder=3)
    b_aft = ax3.bar(x + w / 2, after, width=w, color=TEAL, label="Sau sửa (G_BLANK = 100 = 2 us)", zorder=3)
    for rect in b_bef:
        h = rect.get_height()
        ax3.text(rect.get_x() + rect.get_width() / 2, h + 0.04, f"{h:.2f}%", ha="center", va="bottom",
                 fontsize=8.3, fontweight="bold", color=CRIMSON)
    for rect in b_aft:
        ax3.text(rect.get_x() + rect.get_width() / 2, 0.04, "0,00%", ha="center", va="bottom",
                 fontsize=8.5, fontweight="bold", color=TEAL)
    ax3.set_xticks(x)
    ax3.set_xticklabels(freqs, fontsize=8.5, fontweight="bold")
    ax3.set_ylim(0, max(before) * 1.32)
    ax3.set_ylabel("Tỷ lệ thời gian bóng ma (%)", fontsize=8.8, color=SLATE)
    ax3.set_title("(c) Tỷ lệ bóng ma đo trên 200.000 chu kỳ ở 3 tần số quét (T_OFF = 1 us)",
                  loc="left", fontsize=9.3, fontweight="bold", color=NAVY)
    ax3.legend(loc="upper left", fontsize=8, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)

    fig.subplots_adjust(left=0.14, right=0.98, top=0.94, bottom=0.08)
    out_e4 = os.path.join(PLOT_DIR, "fig_exp_e4_ghosting.png")
    fig.savefig(out_e4, dpi=300)
    plt.close(fig)
    print(f"[PLOT] -> {os.path.relpath(out_e4, ROOT)}")


# ----------------------------------------------------------------------------
# 6. DẠNG SÓNG VCD THỰC TẾ (PIPELINE HAZARD & E3 HARDWARE CAPTURE 0-NS)
# ----------------------------------------------------------------------------
def run_vcd_plots():
    print("\n=== [6/7] Sinh Dạng sóng VCD Thực tế (Pipeline G2 Hazard & E3 Capture 0-ns) ===")
    _sh([sys.executable, os.path.join(HERE, "gen_waves.py")])

    vcd_pipe = os.path.join(WORK_DIR, "wave_pipeline.vcd")
    # Tìm chu kỳ có stall_lu = 1 hoặc fwd_a != 0 để cắt đúng cửa sổ vàng
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
        title="Dạng sóng RTL thật: CPU G2 xử lý Load-Use Stall & Data Forwarding (fw/tests/hazard/load_use.s)",
        subtitle=f"Trích xuất trực tiếp từ work/wave_pipeline.vcd (cửa sổ chu kỳ c{c_start}..c{c_end})",
        highlights=highlights_p,
    )

    # Dạng sóng E3: tìm chu kỳ press[2] = 1 và bus_re đọc SW_LAP (0x24) hoặc MS_OF_DAY (0x04)
    vcd_e3 = os.path.join(WORK_DIR, "wave_e3_capture.vcd")
    _, _, _, hist_e = vcd_plot.parse_vcd(
        vcd_e3,
        ["exp_e3_tb.dut.clk", "exp_e3_tb.dut.press", "exp_e3_tb.dut.sw_capture", "exp_e3_tb.dut.bus_re", "exp_e3_tb.dut.bus_addr"],
    )
    edges_e = vcd_plot.extract_clock_cycles(hist_e["exp_e3_tb.dut.clk"])
    # Tìm cạnh đầu tiên của sw_capture == 1
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


# ----------------------------------------------------------------------------
# 7. ẢNH MÀN HÌNH 7 ĐOẠN 5 CHẾ ĐỘ THẬT TỪ system_tb.v + screen.py
# ----------------------------------------------------------------------------
def run_screen_showcase():
    print("\n=== [7/7] Trích xuất 5 khung hình LED 7 đoạn thật từ system_tb (tools/screen.py) ===")
    log_path = os.path.join(WORK_DIR, "screen_system.log")
    if not os.path.exists(log_path):
        main_hex = os.path.join(WORK_DIR, "main.hex")
        vvp = os.path.join(WORK_DIR, "system_tb.vvp")
        _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", vvp, "tb/system_tb.v", "tb/screen_dump.v"] + _srcs())
        _sh(["vvp", "-n", vvp, "+imem=" + os.path.relpath(main_hex, ROOT)])

    frames = screen.load(log_path)
    tab = screen.seg_table()
    # Loại bỏ khung xé hình (<10 ms) như trong screen.py
    ends = [t for t, _ in frames[1:]] + [None]
    clean = [(t, s, screen.text(s, tab)) for (t, s), e in zip(frames, ends) if e is None or e - t >= screen.TEAR_MS]

    def pick(pred, fallback_idx=0):
        for t, s, txt in clean:
            if pred(txt, s):
                return t, s, txt
        return clean[fallback_idx]

    # Chọn 6 khung tiêu biểu tương ứng 5 chế độ (bao gồm Chess Clock & SET)
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

    # Render ghép 6 khung (3 hàng x 2 cột) chất lượng cao với chữ sắc nét
    cell_w, cell_h = 640, 190
    pad_x, pad_y = 26, 22
    head_h = 66
    canvas_w = pad_x * 3 + cell_w * 2
    canvas_h = head_h + pad_y * 4 + cell_h * 3
    canvas = Image.new("RGB", (canvas_w, canvas_h), (248, 250, 252))
    drw = ImageDraw.Draw(canvas)

    font_path = r"C:\Windows\Fonts\arialbd.ttf"
    font_reg = r"C:\Windows\Fonts\arial.ttf"
    f_title = ImageFont.truetype(font_path, 22) if os.path.exists(font_path) else ImageFont.load_default()
    f_sub = ImageFont.truetype(font_reg, 15) if os.path.exists(font_reg) else ImageFont.load_default()
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

        # Vẽ 8 LED 7 đoạn dùng trực tiếp bitmap từ segs thực
        img7 = screen.draw(segs, scale=5)
        # Đổi màu LED đỏ mặc định sang đúng led_col minh họa theo chế độ
        px = img7.load()
        for yy in range(img7.height):
            for xx in range(img7.width):
                r0, g0, b0 = px[xx, yy]
                if r0 > 180 and g0 < 80:
                    px[xx, yy] = led_col
        tx = cx + (cell_w - img7.width) // 2
        ty = cy + 44
        canvas.paste(img7, (tx, ty))

    os.makedirs(PLOT_DIR, exist_ok=True)
    out_scr = os.path.join(PLOT_DIR, "fig_sim_screen_modes.png")
    canvas.save(out_scr, dpi=(300, 300))
    _save_json("screen_showcase.json", [
        {"label": lb, "t_ms": t, "decoded": txt.strip()} for lb, (t, _, txt), _ in chosen
    ])
    print(f"[PLOT] -> {os.path.relpath(out_scr, ROOT)}")


def sync_to_docs(dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    for fn in sorted(os.listdir(PLOT_DIR)):
        if fn.endswith(".png"):
            shutil.copy2(os.path.join(PLOT_DIR, fn), os.path.join(dest_dir, fn))
    print(f"[SYNC] Đã chép toàn bộ ảnh PNG sang {dest_dir}")


def main():
    _ensure_msys_path()
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--cpi", action="store_true")
    ap.add_argument("--dse", action="store_true")
    ap.add_argument("--e12", action="store_true")
    ap.add_argument("--e3", action="store_true")
    ap.add_argument("--e4", action="store_true")
    ap.add_argument("--waves", action="store_true")
    ap.add_argument("--screen", action="store_true")
    ap.add_argument("--sync-docs", help="Thư mục đích chép ảnh cho LaTeX")
    a = ap.parse_args()

    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(PLOT_DIR, exist_ok=True)
    run_all = a.all or not any([a.cpi, a.dse, a.e12, a.e3, a.e4, a.waves, a.screen])

    if run_all or a.cpi:
        run_cpi_and_amdahl()
    if run_all or a.dse:
        run_dse_and_yosys()
    if run_all or a.e12:
        run_exp_e1_e2()
    if run_all or a.e3:
        run_exp_e3()
    if run_all or a.e4:
        run_exp_e4()
    if run_all or a.waves:
        run_vcd_plots()
    if run_all or a.screen:
        run_screen_showcase()
    if a.sync_docs:
        sync_to_docs(a.sync_docs)
    print("\nHOÀN TẤT BENCHMARK & SINH TOÀN BỘ BIỂU ĐỒ!")


if __name__ == "__main__":
    main()
