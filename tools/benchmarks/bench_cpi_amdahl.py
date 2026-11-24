# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/benchmarks/bench_cpi_amdahl.py — Benchmark CPI G1 vs G2 & Amdahl
# CHUYÊN ĐỀ KTMT: Chương 01 & 04: Phương trình Iron Law, Pipeline G2 & Định luật Amdahl
# VAI TRÒ:        Đo vết retire RTL thực tế trên G1/G2, xuất cpi_benchmark.json & 3 biểu đồ PNG.
# ============================================================================
"""Benchmark 1/7: So sánh CPI G1 vs G2, phân rã chu kỳ G2 và Định luật Amdahl."""

import os
import sys

import matplotlib.pyplot as plt
import numpy as np

from common import (
    AMBER, CRIMSON, DATA_DIR, GRID, NAVY, PLOT_DIR, ROOT, SLATE, TEAL, WORK_DIR,
    _ensure_msys_path, _helpers, _save_json, _sh, _srcs, _style_ax,
)
import asm  # noqa: E402
import cpi  # noqa: E402


def run_cpi_and_amdahl():
    """Chạy benchmark CPI G1 vs G2 trên RTL thật và sinh 3 đồ thị phân tích."""
    _ensure_msys_path()
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(PLOT_DIR, exist_ok=True)
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
    mips_g1 = 25.0 / scpi1
    mips_g2 = 50.0 / scpi2
    fw_entry = {
        "name": "main.s (SoC)",
        "g1": sr1, "cpi_g1": round(scpi1, 4), "mips_g1": round(mips_g1, 3),
        "g2": sr2, "cpi_g2": round(scpi2, 4), "mips_g2": round(mips_g2, 3),
        "throughput_gain_pct": round((mips_g2 / mips_g1 - 1.0) * 100.0, 2),
        "speedup": round(mips_g2 / mips_g1, 3),
    }

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
    ax.set_title(f"Phân rã {bd['total_cyc']:,} chu kỳ thực thi trên CPU G2 (tools/benchmarks/cpi.py)",
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


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    run_cpi_and_amdahl()
