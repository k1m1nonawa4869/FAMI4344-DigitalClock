# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/benchmarks/run_all.py — Điều phối Bộ Benchmark Thực Tế & Sinh Biểu Đồ
# CHUYÊN ĐỀ KTMT: Toàn hệ thống: Hiệu năng CPI/Amdahl, DSE Yosys, Thực nghiệm E1'–E4', Sóng VCD & LED 7 Đoạn
# VAI TRÒ:        Điểm vào CLI gọn nhẹ gọi 6 module benchmark độc lập trong `tools/benchmarks/`,
#                 xuất dữ liệu JSON ra results/data/*.json và ảnh 300 DPI ra results/plots/*.png.
# ============================================================================
"""Chạy toàn bộ benchmark trực tiếp trên WatchChip RTL & sinh ảnh cho Báo cáo/Slide.

Ví dụ (dùng Python trong môi trường conda data-science-env):
    D:\\miniconda3-pbe\\envs\\data-science-env\\python.exe tools/benchmarks/run_all.py --all
    D:\\miniconda3-pbe\\envs\\data-science-env\\python.exe tools/benchmarks/run_all.py --cpi --dse --sync-docs ../../docs/report_archive/latex/hinh/generated
"""

import argparse
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from common import DATA_DIR, PLOT_DIR, _ensure_msys_path, sync_to_docs  # noqa: E402
from bench_cpi_amdahl import run_cpi_and_amdahl  # noqa: E402
from bench_dse_yosys import run_dse_and_yosys  # noqa: E402
from bench_e1_e2 import run_exp_e1_e2  # noqa: E402
from bench_e3 import run_exp_e3  # noqa: E402
from bench_e4 import run_exp_e4  # noqa: E402
from bench_visuals import run_screen_showcase, run_vcd_plots  # noqa: E402


def main():
    """Phân tích tham số dòng lệnh và thực thi các nhóm benchmark được chọn."""
    _ensure_msys_path()
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="Chạy bộ benchmark RTL WatchChip SoC và sinh biểu đồ 300 DPI.")
    ap.add_argument("--all", action="store_true", help="Chạy đủ 7 nhóm benchmark")
    ap.add_argument("--cpi", action="store_true", help="CPI G1 vs G2, phân rã G2 và Định luật Amdahl")
    ap.add_argument("--dse", action="store_true", help="DSE fmt.s và tổng hợp tài nguyên Yosys 0.66")
    ap.add_argument("--e12", action="store_true", help="Thí nghiệm E1' (CAL ppm) và E2' (2000 ms)")
    ap.add_argument("--e3", action="store_true", help="Thí nghiệm E3 (Polling vs Ngắt IRQ vs HW Capture 0 ns)")
    ap.add_argument("--e3-n", type=int, default=60, help="Số lần bấm mỗi ca D trong thí nghiệm E3 (mặc định 60)")
    ap.add_argument("--e4", action="store_true", help="Thí nghiệm E4' (Chống bóng ma LED 7 đoạn)")
    ap.add_argument("--waves", action="store_true", help="Sinh sóng VCD và xuất ảnh Pipeline/E3")
    ap.add_argument("--screen", action="store_true", help="Trích xuất 6 khung LED 7 đoạn từ system_tb")
    ap.add_argument("--sync-docs", help="Thư mục đích chép toàn bộ ảnh PNG cho LaTeX")
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
        run_exp_e3(n_press=a.e3_n)
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
