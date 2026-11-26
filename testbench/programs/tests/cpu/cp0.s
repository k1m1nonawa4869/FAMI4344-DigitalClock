# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/tests/cpu/cp0.s — Kiểm Thử Bộ Đồng Xử Lý Hệ Thống CP0
# CHUYÊN ĐỀ KTMT: Chương 04 & Chương 05: Ngoại Lệ, Ngắt & Thanh Ghi Điều Khiển Hệ Thống (CP0)
# VAI TRÒ:        Kiểm chứng các lệnh mfc0, mtc0, eret trên các thanh ghi Status ($12), Cause ($13), EPC ($14)
# MÔ TẢ:          Xác nhận trạng thái reset, quyền ghi các bit cấu hình và cơ chế nhảy phục hồi từ EPC.
# ============================================================================
# CP0 theo spec nhóm (isa-spec §5; MARS khác ở Status reset và bit ghi được nên không chạy MARS)
# nomars
# expect $t0=0
# expect $t1=3
# expect $t2=0x100
# expect $t3=0
# expect $t4=0
# expect $t5=1
        mfc0  $t0, $12              # Status reset = 0
        li    $t9, 0xffffffff
        mtc0  $t9, $12              # chỉ [1:0] ghi được
        mfc0  $t1, $12
        li    $t9, 0x103
        mtc0  $t9, $14              # EPC: 2 bit thấp ép 0
        mfc0  $t2, $14
        mfc0  $t3, $13              # Cause: IP = 0 (tb irq_ip = 0)
        mtc0  $t9, $13              # ghi Cause bị bỏ
        mfc0  $t4, $13
        jal   go
        mfc0  $t5, $12              # sau eret: EXL = 0, IE = 1
        j     end
go:     mtc0  $ra, $14
        eret
end:    nop
