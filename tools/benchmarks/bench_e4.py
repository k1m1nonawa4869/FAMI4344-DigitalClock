# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/benchmarks/bench_e4.py — Benchmark Thực nghiệm E4' (Bóng ma LED)
# CHUYÊN ĐỀ KTMT: Chương 05: Quét đa hợp LED 7 đoạn & Khoảng trống Anode Blanking
# VAI TRÒ:        Chạy exp_e4_tb.v ở 125 Hz / 500 Hz / 2 kHz, xuất exp_e4.json & PNG.
# ============================================================================
"""Benchmark 5/7: Thực nghiệm E4' (Chống bóng ma LED 7 đoạn đạt 0,00%)."""

import csv
import os
import re
import sys

import matplotlib.pyplot as plt
import numpy as np

from common import (
    AMBER, CRIMSON, DATA_DIR, GRID, NAVY, PLOT_DIR, ROOT, SLATE, TEAL, WORK_DIR,
    _ensure_msys_path, _save_json, _sh, _srcs, _style_ax,
)


def run_exp_e4():
    """Chạy `exp_e4_tb.v`, ghi CSV sóng chuyển khe và vẽ đồ thị chứng minh 0,00%."""
    _ensure_msys_path()
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(PLOT_DIR, exist_ok=True)
    os.makedirs(WORK_DIR, exist_ok=True)

    print("\n=== [5/7] Chạy Thực nghiệm E4' (Chống bóng ma LED 7 đoạn) ===")
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


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    run_exp_e4()
