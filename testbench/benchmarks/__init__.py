# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# GÓI CÔNG CỤ:    tools/benchmarks — Bộ Benchmark Thực Tế, DSE Yosys & Vẽ Đồ Thị
# ============================================================================
"""Gói benchmark, thực nghiệm RTL (E1'–E4'), tổng hợp Yosys và xuất biểu đồ 300 DPI.

Các module chính:
  - common.py            : Đường dẫn, isolate DLL Conda/MSYS2, helper Icarus/JSON/Matplotlib
  - bench_cpi_amdahl.py  : CPI G1 vs G2, phân rã chu kỳ G2 và Định luật Amdahl
  - bench_dse_yosys.py   : DSE định dạng 8 chữ số (fmt.s) & tổng hợp Yosys 0.66
  - bench_e1_e2.py       : Thí nghiệm E1' (CAL ppm) & E2' (tích lũy 2.000 ms)
  - bench_e3.py          : Thí nghiệm E3 (Polling vs Ngắt IRQ vs HW Capture 0 ns)
  - bench_e4.py          : Thí nghiệm E4' (Chống bóng ma LED 7 đoạn)
  - bench_visuals.py     : Trích xuất dạng sóng VCD & 6 khung hình LED 7 đoạn từ system_tb
  - run_all.py           : Điểm vào CLI điều phối toàn bộ 7 nhóm benchmark
"""
