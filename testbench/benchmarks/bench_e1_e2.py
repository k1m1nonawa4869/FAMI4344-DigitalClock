# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    testbench/benchmarks/bench_e1_e2.py — Benchmark Thực nghiệm E1' & E2'
# CHUYÊN ĐỀ KTMT: Chương 05: Bộ định thời phân số chính xác cao & Hiệu chỉnh trôi thạch anh CAL
# VAI TRÒ:        Chạy exp_cal_tb.v (E1' 7 mức ppm + E2' 2.000 ms), xuất exp_e1_e2.json & PNG.
# ============================================================================
"""Benchmark 3/7: Thực nghiệm E1' (hiệu chuẩn ppm CAL) và E2' (bộ tích lũy 2.000 ms)."""

from concurrent.futures import ThreadPoolExecutor
import os
import re
import sys

import matplotlib.pyplot as plt
import numpy as np

from common import (
    CRIMSON, DATA_DIR, GRID, NAVY, PLOT_DIR, ROOT, SLATE, TEAL, WORK_DIR,
    _ensure_msys_path, _save_json, _sh, _srcs, _style_ax,
)
import exp_cal  # noqa: E402


def run_exp_e1_e2():
    """Chạy thí nghiệm E1' & E2' trên RTL `timebase` và xuất đồ thị kiểm chứng."""
    _ensure_msys_path()
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(PLOT_DIR, exist_ok=True)
    os.makedirs(WORK_DIR, exist_ok=True)

    print("\n=== [3/7] Chạy Thực nghiệm E1' & E2' (Hiệu chuẩn ppm & Tích lũy 2000 ms) ===")
    vvp = os.path.join(WORK_DIR, "exp_cal_tb.vvp")
    _sh(["iverilog", "-g2005", "-Wall", "-Wno-timescale", "-o", vvp, "testbench/hdl/exp_cal_tb.v"] + _srcs())

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


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    run_exp_e1_e2()
