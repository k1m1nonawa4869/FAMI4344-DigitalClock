# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/tests/hazard/cp0.s — Kiểm Thử Pipeline G2: Xung Đột Lệnh Hệ Thống CP0
# CHUYÊN ĐỀ KTMT: Chương 04: Forwarding Cho CP0 & Xả Lệnh Khi Phục Hồi Ngắt (eret Flush)
# VAI TRÒ:        Xác nhận mtc0->mfc0 không bị stall và eret nạp lại PC gây xả 2 lệnh (bubbles = 2)
# MÔ TẢ:          Kiểm tra cập nhật tức thời thanh ghi EPC và tự động xóa cờ EXL sau lệnh eret.
# ============================================================================
# B6 cp0 — mtc0/mfc0 cùng thanh ghi không stall (T6); eret nhảy về EPC, phạt 2 (pipeline-policy §5, T6).
# eret lấy EPC; EXL ← 0 nên mfc0 Status sau eret = 1 (IE = 1, EXL = 0).
# bubbles 2
# expect $t1=3
# expect $t4=0x24
# expect $t5=3
# expect $t6=0
# expect $t7=1
        li    $t0, 3
        mtc0  $t0, $12              # Status = 3
        mfc0  $t1, $12              # ngay sau mtc0: đọc Status mới → 3 (0 stall)
        li    $t3, 0x24             # back = 0x24 (li 1 lệnh; không dùng la vì assembler nở la thành 2 lệnh, MARS thì 1)
        mtc0  $t3, $14              # EPC = back
        mfc0  $t4, $14              # → back (0x24)
        mfc0  $t5, $12              # EXL vẫn 1 → 3
        eret                        # nhảy về EPC: 2
        li    $t6, 111              # bị xóa
back:   mfc0  $t7, $12              # EXL đã về 0 → 1
