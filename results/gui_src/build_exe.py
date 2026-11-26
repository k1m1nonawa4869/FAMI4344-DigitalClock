#!/usr/bin/env python3
# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    results/gui_src/build_exe.py — Trình Biên Dịch WatchChip.exe
# CHUYÊN ĐỀ KTMT: Chương 05: Hệ thống Vào/Ra & Đóng gói Ứng dụng Sản phẩm
# VAI TRÒ:        Biên dịch mã nguồn Win32 C++ (watchchip_win32.cpp) bằng g++
#                 thành tệp thực thi độc lập results/WatchChip.exe (~100 KB).
# ============================================================================
"""Biên dịch results/gui_src/watchchip_win32.cpp -> results/WatchChip.exe bằng g++."""

import os
import shutil
import subprocess
import sys

GUI_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.dirname(GUI_DIR)
SRC = os.path.join(GUI_DIR, "watchchip_win32.cpp")
OUT = os.path.join(RESULTS_DIR, "WatchChip.exe")


def main():
    gpp = shutil.which("g++") or r"C:\Strawberry\c\bin\g++.exe"
    if not os.path.exists(gpp) and not shutil.which(gpp):
        sys.exit("Không tìm thấy trình biên dịch g++ để tạo WatchChip.exe.")
    cmd = [
        gpp,
        "-O2",
        "-std=c++17",
        "-mwindows",
        SRC,
        "-o",
        OUT,
        "-lgdi32",
        "-lwinmm",
        "-luser32",
        "-lkernel32",
    ]
    print("[build_exe]", " ".join(cmd))
    subprocess.check_call(cmd, cwd=RESULTS_DIR)
    print(f"[build_exe] OK -> {OUT} ({os.path.getsize(OUT):,} bytes)")


if __name__ == "__main__":
    main()
