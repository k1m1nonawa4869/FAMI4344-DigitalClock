# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    testbench/sim_tools/fw_build.py — Script tự động biên dịch firmware cho SoC WatchChip
# CHUYÊN ĐỀ KTMT: Chương 04: Kiến trúc tập lệnh ISA & Quy trình xây dựng phần mềm nhúng (Firmware Flow)
# VAI TRÒ:        Giao diện dòng lệnh tự động gọi asm.py chuyển đổi mã nguồn firmware (.s) sang mã máy (.hex).
# MÔ TẢ:          - Quản lý quá trình dịch mã nguồn Assembly sang định dạng hex tương thích Verilog $readmemh.
#                 - Hỗ trợ cờ tùy chọn biên dịch qua bộ dịch nội bộ asm.py hoặc kiểm tra chéo qua MARS 4.5.
#                 - Tự động tạo thư mục đích (work/) và xuất file listing phục vụ gỡ lỗi mã máy.
# ============================================================================

"""Dịch firmware .s → .hex cho IMEM.

  python testbench/sim_tools/fw_build.py testbench/programs/demo/clock.s work/clock.hex          # asm.py (B1), mặc định từ 03/10
  python testbench/sim_tools/fw_build.py --mars testbench/programs/demo/clock.s work/clock.hex   # MARS 4.5 như trước (bcd qua teq, .org → nop)

Từ 03/10 dùng `tools/asm.py`: cho ra .hex giống MARS từng word với mọi file trong fw/ (tools/test_asm.py B1-2),
nhanh hơn, không cần Java, có `.lst` và báo lỗi có số dòng.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def main():
    args = sys.argv[1:]
    use_mars = "--mars" in args
    args = [a for a in args if a != "--mars"]
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)
    src, hexf = args
    os.makedirs(os.path.dirname(os.path.abspath(hexf)), exist_ok=True)
    if use_mars:
        from cosim_mars import mars_assemble
        _, n = mars_assemble(src, hexf)
    else:
        import asm
        if asm.main([src, "-o", hexf, "--aw", "11"]) != 0:   # soc_top G_IMEM_AW = 11 (main.s > 1024 lệnh, 26/10)
            sys.exit(1)
        return
    print("%s: %d word -> %s" % (src, n, hexf))


if __name__ == "__main__":
    main()
