# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/tests/hazard/zero_reg.s — Kiểm Thử Pipeline G2: Bất Biến Thanh Ghi $zero ($0)
# CHUYÊN ĐỀ KTMT: Chương 04: Bảo Vệ Thanh Ghi $0 Trong Mạng Forwarding & Hazard Unit
# VAI TRÒ:        Ngăn chặn lỗi Forwarding Unit đẩy nhầm kết quả ALU của lệnh ghi vào đích $0
# MÔ TẢ:          Thực hiện ghi giá trị khác 0 vào $zero rồi đọc ngay ở các lệnh kế tiếp, bảo đảm luôn bằng 0.
# ============================================================================
# B6 zero_reg — ghi vào $0 rồi dùng $0: không được forward giá trị vừa "ghi" (pipeline-policy §2, §3).
# bubbles 0
# expect $t0=5
# expect $t1=0
# expect $t2=0
# expect $t3=7
        li    $s0, 5
        addu  $zero, $s0, $s0       # ghi $0: bỏ qua
        addu  $t0, $zero, $s0       # t0 = 0 + 5 = 5 (không lấy 10)
        addiu $zero, $zero, 7       # ghi $0 lần nữa
        addu  $t1, $zero, $zero     # t1 = 0
        addu  $t2, $zero, $zero     # t2 = 0
        addiu $t3, $zero, 7         # t3 = 7
