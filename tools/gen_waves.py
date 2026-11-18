#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/gen_waves.py — Bộ Tạo Sóng Mô Phỏng & Khởi Chạy GTKWave
# CHUYÊN ĐỀ KTMT: Chương 04, 05: Kiểm chứng Vi kiến trúc Pipeline, Khối Định thời & Ngoại vi
# VAI TRÒ:        Tự động biên dịch RTL, nạp firmware mẫu, trích xuất 3 file sóng .vcd
#                 tương ứng với 3 file cấu hình GTKWave (.gtkw) phục vụ bảo vệ đồ án.
# ============================================================================

import os
import sys
import subprocess
import glob

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WORK_DIR = os.path.join(REPO_ROOT, "work")
SIM_DIR = os.path.join(REPO_ROOT, "sim")

def run_cmd(cmd, desc=""):
    print(f"[*] {desc}: {cmd}")
    res = subprocess.run(cmd, shell=True, cwd=REPO_ROOT, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[!] LOI {desc} (code {res.returncode}):")
        if res.stdout:
            print(res.stdout)
        if res.stderr:
            print(res.stderr)
        return False
    return True

def main():
    os.makedirs(WORK_DIR, exist_ok=True)
    os.makedirs(SIM_DIR, exist_ok=True)

    print("=" * 78)
    print("WATCHCHIP SoC: BỘ TẠO DẠNG SÓNG VCD & CẤU HÌNH GTKWAVE PHỤC VỤ BẢO VỆ")
    print("=" * 78)

    # ------------------------------------------------------------------------
    # 1. TẠO SÓNG PIPELINE G2: work/wave_pipeline.vcd
    # ------------------------------------------------------------------------
    print("\n--- 1. Biên dịch & Sinh sóng Pipeline G2 (Hazard / Forwarding) ---")
    ok1 = run_cmd("python tools/fw_build.py fw/tests/hazard/load_use.s work/wave_pipeline.hex", "Dich firmware load_use.s")
    if ok1:
        pipe_srcs = "src/cpu_pipe.v src/regfile.v src/control.v src/alu.v src/muldiv.v src/bcd_unit.v src/hazard.v src/irq_ctrl.v"
        ok1 = run_cmd(f"iverilog -g2005 -Wall -Wno-timescale -o work/cpu_pipe_tb.vvp tb/cpu_pipe_tb.v {pipe_srcs}", "Bien dich cpu_pipe_tb")
    if ok1:
        # Chạy 80 chu kỳ để ghi lại trọn vẹn hiện tượng Load-Use Hazard Stall và Forwarding
        ok1 = run_cmd("vvp work/cpu_pipe_tb.vvp +imem=work/wave_pipeline.hex +maxcyc=80 +vcd=work/wave_pipeline.vcd", "Mo phong ghi work/wave_pipeline.vcd")
    
    if os.path.exists(os.path.join(WORK_DIR, "wave_pipeline.vcd")):
        size_kb = os.path.getsize(os.path.join(WORK_DIR, "wave_pipeline.vcd")) / 1024
        print(f"[OK] Da sinh thanh cong: work/wave_pipeline.vcd ({size_kb:.1f} KB)")
    else:
        print("[!] Canh bao: Khong tim thay work/wave_pipeline.vcd")

    # Danh sách tất cả file Verilog trong src/ được expand bằng Python (tương thích Windows cmd)
    all_srcs = " ".join([f.replace("\\", "/") for f in sorted(glob.glob(os.path.join(REPO_ROOT, "src", "*.v")))])

    # ------------------------------------------------------------------------
    # 2. TẠO SÓNG THỰC NGHIỆM E3: work/wave_e3_capture.vcd (Chốt Lap 0-ns)
    # ------------------------------------------------------------------------
    print("\n--- 2. Biên dịch & Sinh sóng Thực nghiệm E3 (Stopwatch Lap Capture 0-ns) ---")
    ok2 = run_cmd("python tools/fw_build.py fw/exp/e3_irq.s work/wave_e3.hex", "Dich firmware e3_irq.s")
    if ok2:
        ok2 = run_cmd(f"iverilog -g2005 -Wall -Wno-timescale -o work/exp_e3_tb.vvp tb/exp_e3_tb.v {all_srcs}", "Bien dich exp_e3_tb")
    if ok2:
        ok2 = run_cmd("vvp work/exp_e3_tb.vvp +imem=work/wave_e3.hex +n=1 +vcd=work/wave_e3_capture.vcd", "Mo phong ghi work/wave_e3_capture.vcd")

    if os.path.exists(os.path.join(WORK_DIR, "wave_e3_capture.vcd")):
        size_kb = os.path.getsize(os.path.join(WORK_DIR, "wave_e3_capture.vcd")) / 1024
        print(f"[OK] Da sinh thanh cong: work/wave_e3_capture.vcd ({size_kb:.1f} KB)")
    else:
        print("[!] Canh bao: Khong tim thay work/wave_e3_capture.vcd")

    # ------------------------------------------------------------------------
    # 3. TẠO SÓNG NGOẠI VI & LED 7 ĐOẠN: work/wave_peripherals.vcd
    # ------------------------------------------------------------------------
    print("\n--- 3. Biên dịch & Sinh sóng Ngoại vi SoC & LED 7 Đoạn Quét Đa Hợp ---")
    ok3 = run_cmd("python tools/fw_build.py fw/main.s work/main.hex", "Dich firmware main.s")
    if ok3:
        ok3 = run_cmd(f"iverilog -g2005 -Wall -Wno-timescale -o work/system_tb.vvp tb/system_tb.v tb/screen_dump.v {all_srcs}", "Bien dich lai system_tb co ho tro +vcd=")
    if ok3:
        # Chạy 3.000 chu kỳ đầu để quan sát quét 8 LED 7 thanh, blanking 100-ns và còi PWM
        ok3 = run_cmd("vvp work/system_tb.vvp +imem=work/main.hex +vcd=work/wave_peripherals.vcd +vcd_cyc=3000", "Mo phong ghi work/wave_peripherals.vcd")

    if os.path.exists(os.path.join(WORK_DIR, "wave_peripherals.vcd")):
        size_kb = os.path.getsize(os.path.join(WORK_DIR, "wave_peripherals.vcd")) / 1024
        print(f"[OK] Da sinh thanh cong: work/wave_peripherals.vcd ({size_kb:.1f} KB)")
    else:
        print("[!] Canh bao: Khong tim thay work/wave_peripherals.vcd")

    # ------------------------------------------------------------------------
    # 4. HƯỚNG DẪN MỞ GTKWAVE
    # ------------------------------------------------------------------------
    print("\n" + "=" * 78)
    print("HƯỚNG DẪN KHỞI CHẠY GTKWAVE TRONG BUỔI BẢO VỆ ĐỒ ÁN:")
    print("=" * 78)
    print("1. Demo CPU Pipeline G2 (IF, ID, EX, MEM, WB, Forwarding, Hazard Unit):")
    print("   gtkwave work/wave_pipeline.vcd sim/gtkwave_pipeline_view.gtkw")
    print("\n2. Demo Thực nghiệm E3 (Chốt mốc Lap phần cứng độ trễ 0-ns):")
    print("   gtkwave work/wave_e3_capture.vcd sim/gtkwave_e3_capture.gtkw")
    print("\n3. Demo Ngoại vi (RTC, Quét 8 LED 7 đoạn, Blanking 100-ns, PWM Beeper, UART):")
    print("   gtkwave work/wave_peripherals.vcd sim/gtkwave_peripherals.gtkw")
    print("=" * 78)

if __name__ == "__main__":
    main()
