# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN FILE:       fw/tests/cpu/fact10.s — Kiểm Thử Lời Gọi Hàm Đệ Quy Qua Ngăn Xếp (Stack)
# CHUYÊN ĐỀ KTMT: Chương 02: Quy Ước Gọi Hàm, Ngăn Xếp ($sp) & Thanh Ghi Địa Chỉ Trả Về ($ra)
# VAI TRÒ:        Kiểm chứng phối hợp hoàn chỉnh giữa jal, jr, sw/lw stack và phép nhân mul
# MÔ TẢ:          Tính 10! = 3.628.800 (0x375F00) bằng đệ quy 10 tầng lưu $ra và đối số $a0 trên stack.
# ============================================================================
# C3-2: giai thừa đệ quy qua stack: fact(10) = 3628800 = 0x375F00
# expect $v0=0x375f00
        li    $sp, 0xff8
        li    $a0, 10
        jal   fact
        sw    $v0, 0x800($zero)
        j     end
fact:   addiu $sp, $sp, -8
        sw    $ra, 4($sp)
        sw    $a0, 0($sp)
        slti  $t0, $a0, 2
        beq   $t0, $zero, rec
        li    $v0, 1
        addiu $sp, $sp, 8
        jr    $ra
rec:    addiu $a0, $a0, -1
        jal   fact
        lw    $a0, 0($sp)
        lw    $ra, 4($sp)
        addiu $sp, $sp, 8
        mul   $v0, $v0, $a0
        jr    $ra
end:    nop
