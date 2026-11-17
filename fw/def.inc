# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TỆP ĐẦU VÀO:    fw/def.inc — Bảng Định Nghĩa Cấu Trúc Dữ Liệu Bộ Nhớ (DMEM)
# VAI TRÒ:        Quy hoạch vùng nhớ dữ liệu DMEM (Data Memory) cho máy trạng
#                 thái FSM đồng hồ số, bộ đệm hiển thị, hàng đợi nhận UART,
#                 và các biến lưu trữ thời gian/cấu hình hệ thống.
# ============================================================================
# 1. KIẾN THỨC HÀN LÂM & GIÁO TRÌNH (ACADEMIC FOUNDATIONS):
#    - Kiến Trúc Harvard Bộ Nhớ Phân Biệt (Harvard Memory Architecture):
#      Hệ thống WatchChip phân tách độc lập giữa bộ nhớ lệnh IMEM (Instruction
#      Memory) và bộ nhớ dữ liệu DMEM (Data Memory). Bộ nhớ DMEM có độ rộng
#      4096 byte (1024 từ 32-bit), truy xuất từ địa chỉ 0x00000000 .. 0x00000FFF.
#    - Bố Cục Vùng Nhớ Dữ Liệu (DMEM Memory Layout Map):
#        + 0x000 .. 0x3FC: Vùng ngăn xếp Stack (tăng trưởng từ 0x3FC lùi về 0)
#        + 0x400 .. 0x47F: Các biến trạng thái FSM, cờ cấu hình và mảng Lap
#        + 0x480 .. 0x49F: Bộ đệm bóng hiển thị LED 7 đoạn (Display RAM Shadow)
#        + 0x4A0 .. 0x53F: Bộ đệm xử lý gói tin đồng bộ thời gian UART (NTP sync)
#        + 0x540 .. 0x54F: Vùng lưu ngữ cảnh ngắt phần mềm (ISR Context Save)
#        + 0x550 .. 0x5DF: Hàng đợi vòng nhận ký tự UART trong ngắt (RX FIFO)
#        + 0x7E0 .. 0x7FF: Khối cấu hình kiểm thử khởi động (Bootloader Config)
# ============================================================================

# ----------------------------------------------------------------------------
# 1. CÁC HẰNG SỐ CHẾ ĐỘ MÁY TRẠNG THÁI (FSM MODES)
# ----------------------------------------------------------------------------
        .eqv  MODE_TIME         0               # Chế độ 0: Xem và hiển thị đồng hồ thời gian thực
        .eqv  MODE_STOPWATCH    1               # Chế độ 1: Bấm giờ thể thao lưu 8 Lap cứng
        .eqv  MODE_TIMER        2               # Chế độ 2: Hẹn giờ đếm lùi bù âm
        .eqv  MODE_ALARM        3               # Chế độ 3: Quản lý 4 mốc báo thức và chuông giờ
        .eqv  MODE_SET          4               # Chế độ 4: Chỉnh giờ thủ công nhấp nháy 2 Hz

# ----------------------------------------------------------------------------
# 2. CÁC MÃ NÚT BẤM (BUTTON CODES & BIT MASKS)
# ----------------------------------------------------------------------------
        .eqv  BTN_ID_MODE       0               # Nút MODE: Chuyển đổi qua lại giữa 5 chế độ
        .eqv  BTN_ID_A          1               # Nút A: Bật/tắt, tăng giá trị, Start/Stop
        .eqv  BTN_ID_B          2               # Nút B: Đổi trường chỉnh, chuyển màn hình, Lap/Reset
        .eqv  BTN_ID_C          3               # Nút C: Chỉnh độ sáng, Snooze, xem Lap

# ----------------------------------------------------------------------------
# 3. ĐỊNH NGHĨA BIẾN FSM & THỜI GIAN TRONG DMEM (0x400 .. 0x43F)
# ----------------------------------------------------------------------------
        .eqv  V_MODE            0x400           # Chế độ FSM hiện tại (0..4)
        .eqv  V_TV              0x404           # Kiểu hiển thị TIME: 0: Giờ:Phút, 1: Giây:ms, 2: Ngày:Thứ
        .eqv  V_H12             0x408           # Định dạng hiển thị giờ: 0: 24h, 1: 12h (AM/PM)
        .eqv  V_BRI             0x40c           # Độ sáng màn hình LED: 15 (sáng nhất) -> 9 -> 3 (tối)
        .eqv  V_PRE             0x410           # Giá trị đặt trước của bộ đếm lùi (mili-giây)
        .eqv  V_ALK             0x414           # Chỉ số báo thức đang chọn: 0..3 (AL1..AL4), 4: Chuông giờ
        .eqv  V_CHIME           0x418           # Cờ cho phép chuông điểm giờ tròn tiếng (Hourly Chime)
        .eqv  V_LASTH           0x41c           # Giờ đã ghi nhận ở chu kỳ trước (-1 nếu vừa khởi động)
        .eqv  V_RING            0x420           # Trạng thái chuông còi: 0: Im lặng, 1: Timer, 2: Báo thức
        .eqv  V_RINGT           0x424           # Thời điểm bắt đầu đổ chuông (ms trong ngày, tự tắt sau 60s)
        .eqv  V_SNZ             0x428           # Mốc thời gian kích hoạt lại chuông tạm hoãn (Snooze +5 phút)
        .eqv  V_SNZON           0x42c           # Cờ báo tính năng tạm hoãn chuông (Snooze) đang bật
        .eqv  V_LAPN            0x430           # Số lượng Lap đã ghi nhận trong bộ nhớ đệm (tối đa 8)
        .eqv  V_LAPI            0x434           # Lap đang chọn để hiển thị: 0: Giờ chạy thực, 1..8: Xem lại Lap
        .eqv  V_SF              0x438           # Trường đang chỉnh trong SET: 0..5 (Giờ, Phút, Giây, Ngày, Tháng, Năm)
        .eqv  V_AED             0x43c           # Trường đang sửa trong ALARM: 0: Không sửa, 1: Giờ, 2: Phút

# ----------------------------------------------------------------------------
# 4. MẢNG LƯU TRỮ 8 LAP BẤM GIỜ (0x440 .. 0x45F)
# ----------------------------------------------------------------------------
        .eqv  V_LAPV            0x440           # 8 từ nhớ 32-bit liên tiếp lưu trữ thời gian của 8 Lap (0x440..0x45C)

# ----------------------------------------------------------------------------
# 5. CÁC BIẾN TẠM CHỈNH GIỜ SET & BÁO THỨC (0x460 .. 0x47F)
# ----------------------------------------------------------------------------
        .eqv  V_SH              0x460           # SET: Giờ tạm thời (0..23)
        .eqv  V_SM              0x464           # SET: Phút tạm thời (0..59)
        .eqv  V_SS              0x468           # SET: Giây tạm thời (0..59)
        .eqv  V_SD              0x46c           # SET: Ngày trong tháng tạm thời (1..31)
        .eqv  V_SMO             0x470           # SET: Tháng trong năm tạm thời (1..12)
        .eqv  V_SY              0x474           # SET: Năm tạm thời (độ lệch tính từ năm 2000, 0..99)
        .eqv  V_AEH             0x478           # ALARM: Giờ báo thức tạm thời đang chỉnh sửa
        .eqv  V_AEM             0x47c           # ALARM: Phút báo thức tạm thời đang chỉnh sửa

# ----------------------------------------------------------------------------
# 6. BỘ ĐỆM BÓNG HIỂN THỊ LED 7 ĐOẠN (DISPLAY BUFFER SHADOW: 0x480 .. 0x49F)
# ----------------------------------------------------------------------------
        .eqv  D0                0x480           # Ô LED 0: Ký tự chữ số ngoài cùng bên phải
        .eqv  D1                0x484           # Ô LED 1
        .eqv  D2                0x488           # Ô LED 2
        .eqv  D3                0x48c           # Ô LED 3
        .eqv  D4                0x490           # Ô LED 4
        .eqv  D5                0x494           # Ô LED 5
        .eqv  D6                0x498           # Ô LED 6
        .eqv  D7                0x49c           # Ô LED 7: Ký tự chữ số ngoài cùng bên trái

# ----------------------------------------------------------------------------
# 7. BỘ ĐỆM XỬ LÝ GÓI ĐỒNG BỘ UART CHÍNH (UART SYNC BUFFER: 0x4A0 .. 0x53F)
# ----------------------------------------------------------------------------
        .eqv  V_SLEN            0x4a0           # Độ dài chuỗi ký tự đang gom (tối đa 32 byte)
        .eqv  V_SQMS            0x4a4           # Thời điểm ms chốt khi nhận ký tự kết thúc '\n'
        .eqv  V_SQDY            0x4a8           # Ngày chốt khi nhận ký tự kết thúc '\n'
        .eqv  V_T1OK            0x4ac           # Cờ báo đã có mốc đồng bộ trước (T1) để tính CAL bù trôi
        .eqv  V_T1MS            0x4b0           # Mốc mili-giây của lần đồng bộ trước T1
        .eqv  V_T1DY            0x4b4           # Mốc ngày của lần đồng bộ trước T1
        .eqv  V_SRDY            0x4b8           # Cờ báo chuỗi đồng bộ sẵn sàng xử lý (đã nhận '\n')
        .eqv  V_DACC            0x4bc           # Sai lệch thời gian tích lũy giữa các lần đồng bộ
        .eqv  V_SBUF            0x4c0           # Mảng bộ đệm chuỗi ký tự xử lý (32 từ nhớ, 0x4C0..0x53C)
        .eqv  V_SBUF1           0x4c4
        .eqv  V_SBUF2           0x4c8

# ----------------------------------------------------------------------------
# 8. VÙNG LƯU NGỮ CẢNH NGẮT (ISR CONTEXT SAVE AREA: 0x540 .. 0x54F)
# ----------------------------------------------------------------------------
        .eqv  V_IT0             0x540           # Nơi cất tạm thời thanh ghi $t0 khi vào ISR
        .eqv  V_IT1             0x544           # Nơi cất tạm thời thanh ghi $t1 khi vào ISR
        .eqv  V_IT2             0x548           # Nơi cất tạm thời thanh ghi $t2 khi vào ISR

# ----------------------------------------------------------------------------
# 9. BỘ ĐỆM NHẬN NGẮT UART ISR (UART RX ISR FIFO BUFFER: 0x550 .. 0x5DF)
# ----------------------------------------------------------------------------
        .eqv  V_RLEN            0x550           # Số byte ký tự gom được trong trình phục vụ ngắt
        .eqv  V_RQMS            0x554           # Tem mili-giây chụp tức thời trong ngắt
        .eqv  V_RQDY            0x558           # Tem ngày chụp tức thời trong ngắt
        .eqv  V_RRDY            0x55c           # Cờ báo bộ đệm ngắt đã gom đủ 1 câu hoàn chỉnh
        .eqv  V_RBUF            0x560           # Mảng lưu trữ câu nhận được từ UART (32 từ nhớ, 0x560..0x5DC)

# ----------------------------------------------------------------------------
# 10. CẤU HÌNH NGẮT & KHỐI KHỞI ĐỘNG (SYSTEM CONFIG & BOOTLOADER: 0x7E0 .. 0x7FF)
# ----------------------------------------------------------------------------
        .eqv  USE_IRQ           1               # Cấu hình ngắt: 1: Dùng ngắt UART_RX tại 0x180; 0: Polling
        .eqv  CFG_MAG           0x7e0           # Từ ma thuật kiểm tra (Magic Word): 0x534F4331 ("SOC1")
        .eqv  CFG_MS            0x7e4           # Giờ nạp cấu hình ban đầu (mili-giây trong ngày)
        .eqv  CFG_DAY           0x7e8           # Ngày nạp cấu hình ban đầu
        .eqv  CFG_PRE           0x7ec           # Thời gian đặt trước mặc định cho đếm lùi (ms)

# ----------------------------------------------------------------------------
# 11. HẰNG SỐ MÃ KÝ TỰ BẢNG TRA ROM (CHAR ROM LOOKUP CONSTANTS)
# ----------------------------------------------------------------------------
        .eqv  CHAR_BLANK        0x1A            # Mã ký tự khoảng trắng (Tắt hết các đoạn LED)
        .eqv  CHAR_DASH         0x10            # Mã ký tự dấu gạch ngang '-' (Đoạn g)
        .eqv  CHAR_DP           0x80            # Mặt nạ bật dấu chấm thập phân (bit 7)
