# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/benchmarks/bench_e3.py — Benchmark Thực nghiệm E3 (Capture 0 ns)
# CHUYÊN ĐỀ KTMT: Chương 05: Polling vs Ngắt IRQ vs Hardware Timestamping
# VAI TRÒ:        Đo độ trễ 360 lần bấm phím ngẫu nhiên qua exp_e3_tb.v, xuất exp_e3.json & PNG.
# ============================================================================
"""Benchmark 4/7: Thực nghiệm E3 (Polling vs Ngắt IRQ vs HW Capture 0 ns)."""

import csv
import os
import sys

import matplotlib.pyplot as plt
import numpy as np

from common import (
    AMBER, BENCH_DIR, CRIMSON, DATA_DIR, GRID, NAVY, PLOT_DIR, ROOT, SLATE, TEAL, WORK_DIR,
    _ensure_msys_path, _save_json, _sh, _srcs, _style_ax,
)
import exp_e3  # noqa: E402


def run_exp_e3(n_press=60):
    """Chạy `exp_e3.py --n n_press`, thống kê min/TB/p95/max và vẽ biểu đồ phân phối."""
    _ensure_msys_path()
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(PLOT_DIR, exist_ok=True)
    os.makedirs(WORK_DIR, exist_ok=True)

    print(f"\n=== [4/7] Chạy Thực nghiệm E3 ({n_press * 6} lần bấm: Polling vs IRQ vs HW Capture) ===", flush=True)
    vvp = os.path.join(WORK_DIR, "exp_e3_tb.vvp")
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", vvp, "tb/exp_e3_tb.v"] + _srcs())
    _sh([sys.executable, os.path.join(BENCH_DIR, "exp_e3.py"), "--n", str(n_press)])

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
    ax1.bar(x - w, poll_mean, width=w, color=CRIMSON, label="Polling (trung bình / vạch max)", zorder=3)
    ax1.bar(x, irq_mean, width=w, color=AMBER, label="Ngắt IRQ (trung bình / vạch max)", zorder=3)
    ax1.bar(x + w, [0, 0, 0], width=w, color=TEAL, label=f"HW Capture SW_LAP (0 ns / {n_press*6} ca)", zorder=3)

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

    fig.suptitle(f"Thí nghiệm E3: Đo đạc {n_press * 6} lần bấm nút ngẫu nhiên trên RTL (tools/benchmarks/exp_e3.py --n {n_press})",
                 fontsize=10.5, fontweight="bold", color=NAVY, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    out_e3 = os.path.join(PLOT_DIR, "fig_exp_e3_latency.png")
    fig.savefig(out_e3, dpi=300)
    plt.close(fig)
    print(f"[PLOT] -> {os.path.relpath(out_e3, ROOT)}")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    run_exp_e3()
