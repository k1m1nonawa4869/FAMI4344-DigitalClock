# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/tests/hazard/multi.s — Kiểm Thử Pipeline G2: Bộ Chia Tuần Tự Đa Chu Kỳ
# CHUYÊN ĐỀ KTMT: Chương 03 & Chương 04: Tích Hợp Bộ Chia Restoring 32 Chu Kỳ Vào Đường Ống Pipeline
# VAI TRÒ:        Đo chính xác tổng số bọt khí (bubbles = 65) khi chạy phép chia và đọc thanh ghi HI/LO
# MÔ TẢ:          Kiểm tra div chuẩn (+32), chia 0 thoát nhanh (+0), mflo/mfhi liên hoàn (+0) và lw -> div (+33).
# ============================================================================
# B6 multi — div K = 33 chu kỳ EX (+32 bubble); chia 0 = 1 chu kỳ (+0); mflo/mfhi ngay sau div (+0);
# lw → div: load-use stall 1 rồi div 32 (+33). Tổng = 32 + 0 + 33 = 65 (pipeline-policy §6, T5).
# bubbles 65
# expect $t0=14
# expect $t1=2
# expect $t2=16
# expect $t3=0
# expect $t4=100
# expect $t6=14
        li    $s0, 100
        li    $s1, 7
        div   $s0, $s1              # 100 / 7: LO = 14, HI = 2
        mflo  $t0                   # 14 (chờ div xong vì mflo nằm sau div)
        mfhi  $t1                   # 2
        addu  $t2, $t0, $t1         # 16
        div   $s0, $zero            # chia 0: LO = 0, HI = rs = 100, 1 chu kỳ
        mflo  $t3                   # 0
        mfhi  $t4                   # 100
        sw    $s1, 0x800($zero)     # M[800] = 7
        lw    $t5, 0x800($zero)     # t5 = 7
        div   $s0, $t5              # rt là load: stall 1, rồi 32 bước
        mflo  $t6                   # 14
