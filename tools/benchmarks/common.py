# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/benchmarks/common.py — Tiện ích dùng chung cho bộ Benchmark
# CHUYÊN ĐỀ KTMT: Quản lý đường dẫn RTL, Conda/MSYS2 DLL, lưu JSON & chuẩn hóa đồ thị Matplotlib
# VAI TRÒ:        Cung cấp cấu hình chung, helper chạy iverilog/vvp và đồng bộ ảnh báo cáo.
# ============================================================================
"""Tiện ích dùng chung cho gói benchmark `tools/benchmarks/`."""

import glob
import json
import os
import shutil
import subprocess
import sys
import types

if "pytest" not in sys.modules:
    try:
        import pytest  # noqa: F401
    except ImportError:
        _pt = types.ModuleType("pytest")
        _pt.mark = types.SimpleNamespace(parametrize=lambda *a, **k: (lambda fn: fn))
        sys.modules["pytest"] = _pt

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = os.path.dirname(BENCH_DIR)
ROOT = os.path.dirname(TOOLS_DIR)

for _p in (TOOLS_DIR, BENCH_DIR):
    if _p not in sys.path:
        sys.path.insert(0, _p)

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
    """Đặt Conda Library/bin lên đầu PATH và thêm MSYS2 ở cuối cho iverilog/vvp/yosys."""
    conda_bins = [p for p in (os.path.join(sys.prefix, "Library", "bin"), sys.prefix) if os.path.isdir(p)]
    for p in conda_bins:
        if hasattr(os, "add_dll_directory"):
            try:
                os.add_dll_directory(p)
            except OSError:
                pass
    msys_bin = r"C:\msys64\ucrt64\bin"
    cur = [
        x for x in os.environ.get("PATH", "").split(os.pathsep)
        if x and os.path.normcase(x) != os.path.normcase(msys_bin)
    ]
    new_path = conda_bins + [x for x in cur if x not in conda_bins]
    if os.path.isdir(msys_bin):
        new_path.append(msys_bin)
    os.environ["PATH"] = os.pathsep.join(new_path)


def _srcs():
    """Trả về danh sách tệp nguồn Verilog trong `src/`."""
    return sorted(glob.glob(os.path.join(ROOT, "src", "*.v")))


def _helpers():
    """Trả về các tệp trợ giúp mô phỏng trong `tb/` (loại trừ `*_tb.v`)."""
    return sorted(f for f in glob.glob(os.path.join(ROOT, "tb", "*.v")) if not f.endswith("_tb.v"))


def _sh(cmd, check=True):
    """Thực thi lệnh shell từ thư mục gốc project và kiểm tra mã thoát."""
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        raise RuntimeError(f"Lệnh lỗi ({r.returncode}): {' '.join(cmd)}\n{r.stdout}\n{r.stderr}")
    return r


def _style_ax(ax):
    """Áp dụng lưới và đường viền chuẩn học thuật cho trục Matplotlib."""
    ax.set_facecolor("#FFFFFF")
    ax.grid(True, linestyle="--", linewidth=0.75, color=GRID, zorder=0)
    ax.set_axisbelow(True)
    for sp in ("top", "right"):
        ax.spines[sp].set_visible(False)
    ax.tick_params(colors=SLATE, labelsize=8.5)


def _save_json(name, obj):
    """Lưu dữ liệu thực nghiệm định dạng JSON vào `results/data/`."""
    os.makedirs(DATA_DIR, exist_ok=True)
    path = os.path.join(DATA_DIR, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    print(f"[DATA] -> {os.path.relpath(path, ROOT)}")
    return path


def sync_to_docs(dest_dir):
    """Sao chép toàn bộ ảnh PNG trong `results/plots/` sang thư mục LaTeX."""
    os.makedirs(dest_dir, exist_ok=True)
    for fn in sorted(os.listdir(PLOT_DIR)):
        if fn.endswith(".png"):
            shutil.copy2(os.path.join(PLOT_DIR, fn), os.path.join(dest_dir, fn))
    print(f"[SYNC] Đã chép toàn bộ ảnh PNG sang {dest_dir}")
