// ============================================================================
// HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
// TÊN TỆP:        results/gui_src/watchchip_win32.cpp — Ứng dụng WatchChip.exe
// CHUYÊN ĐỀ KTMT: Chương 05: Hệ thống Vào/Ra (I/O) & Đồng thiết kế Phần cứng / Phần mềm
// VAI TRÒ:        Ứng dụng desktop Windows độc lập tái hiện mặt đồng hồ 8 LED 7 đoạn
//                 cùng 4 nút bấm tròn (M, A, B, C), kết nối trực tiếp backend Verilog thật.
// MÔ TẢ:          - Tự định vị thư mục gốc dự án, tự gọi tools/asm.py và iverilog -g2005
//                   khi work/main.hex hoặc work/live_soc_tb.vvp thiếu hoặc cũ hơn nguồn.
//                 - Chạy `vvp -n work/live_soc_tb.vvp +imem=work/main.hex` ẩn cửa sổ console,
//                   trao đổi lệnh "<mask> <n_ms>" qua Win32 Anonymous Pipe theo nhịp ~47 ms.
//                 - Vẽ 8 chữ số 7 đoạn (có độ dày vát cạnh, dấu chấm dp, 4 màu LED V_COLOR
//                   cập nhật trực tiếp từ firmware, vách chia Cờ vua) và 4 nút tròn (M/A/B/C)
//                   hỗ trợ cả click chuột lẫn phím bấm, kèm âm bíp Win32 không chặn UI.
//                 - Hỗ trợ `--selftest <file>` và `--capture <out.bmp> <script> [hold_mask]`
//                   để tự động kiểm chứng đầu-cuối và xuất ảnh thật cho README / Báo cáo / Slide.
// ============================================================================

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <queue>
#include <sstream>
#include <string>
#include <vector>

// ----------------------------------------------------------------------------
// 1. CẤU HÌNH GIAO DIỆN & THÔNG SỐ GIAO THỨC RTL
// ----------------------------------------------------------------------------
static const int WIN_W       = 780;
static const int WIN_H       = 372;
static const int STEP_MS     = 47;   // Nguyên tố cùng nhau với 10 -> hàng 1/1000 s nhảy đủ 0..9
static const int PRESS_STEPS = 2;    // Giữ nút 2 bước = 94 ms (> khóa rung 10 ms trong buttons.v)
static const int GAP_STEPS   = 2;    // Nhả 2 bước = 94 ms giữa hai lần bấm liên tiếp
static const UINT_PTR TIMER_ID = 101;

// Bốn chủ đề màu LED khớp V_COLOR (0..3) trong firmware/time_mode.s
static const COLORREF LED_LIT_COLS[4] = {
    RGB(255,  58,  48),   // 0: Đỏ
    RGB( 38, 238, 112),   // 1: Xanh lá
    RGB( 45, 224, 255),   // 2: Xanh lam (Cyan)
    RGB(255, 204,  40),   // 3: Vàng hổ phách
};
static const COLORREF LED_DIM_COLS[4] = {
    RGB( 44,  18,  20),
    RGB( 16,  42,  26),
    RGB( 16,  38,  46),
    RGB( 46,  38,  16),
};
static const char* LED_NAMES[4] = {"RED", "GREEN", "CYAN", "AMBER"};

// Vị trí 4 nút bấm tròn ở đáy cửa sổ (bit0=M, bit1=A, bit2=B, bit3=C)
struct RoundButton {
    int cx, cy, r;
    const char* key_label;
    const char* sub_label;
};
static const RoundButton BUTTONS[4] = {
    {135, 296, 33, "M", "MODE"},
    {305, 296, 33, "A", "A / START"},
    {475, 296, 33, "B", "B / VIEW / LAP"},
    {645, 296, 33, "C", "C / COLOR"},
};

struct FrameState {
    int      t_ms     = 0;
    uint8_t  segs[8]  = {0};
    int      color    = 0;
    int      mode     = 0;
    bool     is_chess = false;
    bool     beep     = false;
    uint8_t  btn_down = 0;      // Bitmask nút đang ấn (hiển thị hiệu ứng lún nút)
    double   speed    = 1.0;
};

// ----------------------------------------------------------------------------
// 2. TIỆN ÍCH HỆ THỐNG TỆP & TỰ ĐỘNG BUILD FIRMWARE / SOURCE VERILOG
// ----------------------------------------------------------------------------
static bool file_exists(const std::string& p) {
    DWORD a = GetFileAttributesA(p.c_str());
    return (a != INVALID_FILE_ATTRIBUTES) && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

static uint64_t file_mtime(const std::string& p) {
    WIN32_FILE_ATTRIBUTE_DATA st{};
    if (!GetFileAttributesExA(p.c_str(), GetFileExInfoStandard, &st)) return 0;
    return (static_cast<uint64_t>(st.ftLastWriteTime.dwHighDateTime) << 32) |
           st.ftLastWriteTime.dwLowDateTime;
}

static uint64_t max_glob_mtime(const std::string& dir, const char* pat1, const char* pat2 = nullptr) {
    uint64_t best = 0;
    const char* pats[2] = {pat1, pat2};
    for (int pi = 0; pi < 2 && pats[pi]; ++pi) {
        WIN32_FIND_DATAA fd{};
        HANDLE h = FindFirstFileA((dir + "\\" + pats[pi]).c_str(), &fd);
        if (h == INVALID_HANDLE_VALUE) continue;
        do {
            if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
                uint64_t t = (static_cast<uint64_t>(fd.ftLastWriteTime.dwHighDateTime) << 32) |
                             fd.ftLastWriteTime.dwLowDateTime;
                if (t > best) best = t;
            }
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
    return best;
}

static std::vector<std::string> list_verilog(const std::string& dir) {
    std::vector<std::string> out;
    WIN32_FIND_DATAA fd{};
    HANDLE h = FindFirstFileA((dir + "\\*.v").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return out;
    do {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
            out.push_back("source/" + std::string(fd.cFileName));
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    std::sort(out.begin(), out.end());
    return out;
}

static std::string find_repo_root() {
    char buf[MAX_PATH]{};
    GetModuleFileNameA(nullptr, buf, MAX_PATH);
    std::string exe_dir(buf);
    size_t pos = exe_dir.find_last_of("\\/");
    if (pos != std::string::npos) exe_dir = exe_dir.substr(0, pos);
    // Kiểm tra từ thư mục chứa exe lên 2 cấp (results\ -> repo root) và thư mục làm việc hiện tại
    std::vector<std::string> cands = {
        exe_dir + "\\..",
        exe_dir,
        ".",
    };
    for (const auto& c : cands) {
        if (file_exists(c + "\\firmware\\main.s") && file_exists(c + "\\source\\soc_top.v")) {
            char abs_buf[MAX_PATH]{};
            GetFullPathNameA(c.c_str(), MAX_PATH, abs_buf, nullptr);
            return std::string(abs_buf);
        }
    }
    return ".";
}

static bool run_hidden_sync(const std::string& cmd, const std::string& cwd) {
    STARTUPINFOA si{};
    PROCESS_INFORMATION pi{};
    si.cb = sizeof(si);
    std::vector<char> mutable_cmd(cmd.begin(), cmd.end());
    mutable_cmd.push_back('\0');
    if (!CreateProcessA(nullptr, mutable_cmd.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, cwd.c_str(), &si, &pi)) {
        return false;
    }
    WaitForSingleObject(pi.hProcess, 60000);
    DWORD rc = 1;
    GetExitCodeProcess(pi.hProcess, &rc);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return rc == 0;
}

static bool ensure_rtl_built(const std::string& root, std::string& err) {
    CreateDirectoryA((root + "\\work").c_str(), nullptr);
    const std::string hex_p = root + "\\work\\main.hex";
    const std::string vvp_p = root + "\\work\\live_soc_tb.vvp";

    uint64_t fw_t = max_glob_mtime(root + "\\firmware", "*.s", "*.inc");
    if (!file_exists(hex_p) || file_mtime(hex_p) < fw_t) {
        if (!run_hidden_sync("python tools/asm.py --aw 11 -o work/main.hex firmware/main.s", root)) {
            err = "Loi bien dich firmware/main.s qua tools/asm.py (can Python 3 trong PATH).";
            return false;
        }
    }

    uint64_t src_t = max_glob_mtime(root + "\\source", "*.v");
    uint64_t tb_t  = file_mtime(root + "\\results\\connector\\live_soc_tb.v");
    if (tb_t > src_t) src_t = tb_t;
    if (!file_exists(vvp_p) || file_mtime(vvp_p) < src_t) {
        std::string cmd = "iverilog -g2005 -Wno-timescale -o work/live_soc_tb.vvp results/connector/live_soc_tb.v";
        for (const auto& s : list_verilog(root + "\\source")) {
            cmd += " " + s;
        }
        if (!run_hidden_sync(cmd, root)) {
            err = "Loi bien dich RTL bang iverilog -g2005 (kiem tra Icarus Verilog trong PATH).";
            return false;
        }
    }
    return true;
}

// ----------------------------------------------------------------------------
// 3. CẦU NỐI PIPE STDIN/STDOUT TỚI TIẾN TRÌNH VVP (CHIP WATCHCHIP THẬT)
// ----------------------------------------------------------------------------
class RtlBackend {
public:
    ~RtlBackend() { close(); }

    bool start(const std::string& root, std::string& err) {
        if (!ensure_rtl_built(root, err)) return false;

        SECURITY_ATTRIBUTES sa{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
        HANDLE out_rd = nullptr, out_wr = nullptr;
        HANDLE in_rd  = nullptr, in_wr  = nullptr;
        if (!CreatePipe(&out_rd, &out_wr, &sa, 0) || !CreatePipe(&in_rd, &in_wr, &sa, 0)) {
            err = "Khong tao duoc Win32 anonymous pipe cho vvp.";
            return false;
        }
        SetHandleInformation(out_rd, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(in_wr, HANDLE_FLAG_INHERIT, 0);

        STARTUPINFOA si{};
        si.cb         = sizeof(si);
        si.dwFlags    = STARTF_USESTDHANDLES;
        si.hStdInput  = in_rd;
        si.hStdOutput = out_wr;
        si.hStdError  = out_wr;

        std::string cmd = "vvp -n work/live_soc_tb.vvp +imem=work/main.hex";
        std::vector<char> mcmd(cmd.begin(), cmd.end());
        mcmd.push_back('\0');

        BOOL ok = CreateProcessA(nullptr, mcmd.data(), nullptr, nullptr, TRUE,
                                 CREATE_NO_WINDOW, nullptr, root.c_str(), &si, &pi_);
        CloseHandle(out_wr);
        CloseHandle(in_rd);
        if (!ok) {
            CloseHandle(out_rd);
            CloseHandle(in_wr);
            err = "Khong khoi chay duoc vvp (kiem tra PATH).";
            return false;
        }
        rd_ = out_rd;
        wr_ = in_wr;

        std::string line;
        while (read_line(line)) {
            if (line.rfind("READY", 0) == 0) return true;
        }
        err = "vvp khong gui tin hieu READY.";
        close();
        return false;
    }

    bool step(int mask, int ms, FrameState& out) {
        if (!wr_ || !rd_) return false;
        char msg[64];
        int len = std::snprintf(msg, sizeof(msg), "%d %d\n", mask & 0xF, ms);
        DWORD written = 0;
        if (!WriteFile(wr_, msg, static_cast<DWORD>(len), &written, nullptr)) return false;

        std::string line;
        while (read_line(line)) {
            if (line.rfind("F ", 0) == 0) {
                int t_ms = 0, beep_i = 0;
                unsigned long long shown = 0ULL;
                unsigned int lit = 0U, col = 0U;
                if (std::sscanf(line.c_str(), "F %d %llx %x %x %d",
                                &t_ms, &shown, &lit, &col, &beep_i) >= 5) {
                    out.t_ms     = t_ms;
                    out.color    = static_cast<int>(col & 0x3U);
                    out.mode     = static_cast<int>((col >> 2) & 0x7U);
                    out.is_chess = ((col >> 5) & 1U) != 0U;
                    out.beep     = (beep_i != 0);
                    for (int idx = 0; idx < 8; ++idx) {
                        int bit_pos = 7 - idx;
                        if ((lit >> bit_pos) & 1U) {
                            out.segs[idx] = static_cast<uint8_t>((shown >> (8 * bit_pos)) & 0xFFULL);
                        } else {
                            out.segs[idx] = 0;
                        }
                    }
                    return true;
                }
            }
        }
        return false;
    }

    void close() {
        if (wr_) { CloseHandle(wr_); wr_ = nullptr; }
        if (rd_) { CloseHandle(rd_); rd_ = nullptr; }
        if (pi_.hProcess) {
            if (WaitForSingleObject(pi_.hProcess, 1500) == WAIT_TIMEOUT) {
                TerminateProcess(pi_.hProcess, 0);
            }
            CloseHandle(pi_.hProcess);
            CloseHandle(pi_.hThread);
            pi_ = {};
        }
    }

private:
    bool read_line(std::string& line) {
        line.clear();
        char ch = 0;
        DWORD got = 0;
        while (ReadFile(rd_, &ch, 1, &got, nullptr) && got == 1) {
            if (ch == '\r') continue;
            if (ch == '\n') return true;
            line.push_back(ch);
        }
        return !line.empty();
    }

    PROCESS_INFORMATION pi_{};
    HANDLE rd_ = nullptr;
    HANDLE wr_ = nullptr;
};

// Luồng phát âm bíp còi tách riêng để không làm chậm nhịp quét LED
static HANDLE g_beep_ev   = nullptr;
static bool   g_beep_quit = false;
static DWORD WINAPI beep_worker(LPVOID) {
    while (!g_beep_quit) {
        WaitForSingleObject(g_beep_ev, INFINITE);
        if (g_beep_quit) break;
        Beep(2000, 75);
    }
    return 0;
}

// ----------------------------------------------------------------------------
// 4. BỘ VẼ GDI DOUBLE-BUFFER: 8 LED 7 ĐOẠN VÁT CẠNH & 4 NÚT TRÒN (M, A, B, C)
// ----------------------------------------------------------------------------
enum SepStyle {
    SEP_DIM_DOT = 0,   // Không bật dấu phân cách (vẫn vẽ chấm mờ ẩn trên bezel)
    SEP_DOT     = 1,   // Một chấm thập phân ở đáy (SS.cc, DD.MM.YYYY, .mmm)
    SEP_COLON   = 2,   // Hai chấm dọc sáng (MM:SS, HH:MM:SS) phân biệt rõ với SS.cc
};

static bool is_chess_display(const FrameState& st) {
    const uint8_t* s = st.segs;
    auto is_half_valid = [&](int base) {
        uint8_t c0 = s[base] & 0x7F;
        uint8_t c1 = s[base + 1] & 0x7F;
        return (c0 != 0) && (c1 != 0); // Loại SET0 (S7, S6 tắt trắng)
    };
    if (st.is_chess && is_half_valid(0) && is_half_valid(4)) return true;
    if (st.mode != 0 && st.mode != 3) return false;
    bool dp1 = (s[1] & 0x80) != 0, dp2 = (s[2] & 0x80) != 0, dp3 = (s[3] & 0x80) != 0;
    bool dp4 = (s[4] & 0x80) != 0, dp5 = (s[5] & 0x80) != 0, dp7 = (s[7] & 0x80) != 0;
    bool is_ampm  = ((s[0] & 0x7F) == 0x77 || (s[0] & 0x7F) == 0x73) && (s[1] & 0x7F) == 0x37;
    bool is_24hms = dp1 && dp3 && dp5 && !dp7;
    bool is_sw    = dp2 && dp4;
    return !is_ampm && !is_24hms && !is_sw && !dp3 && (dp1) && (dp5 || dp7) && is_half_valid(0) && is_half_valid(4);
}

static void classify_separators(const FrameState& st, bool chess, SepStyle sep_out[8],
                                const char*& left_tag, const char*& right_tag) {
    const uint8_t* s = st.segs;
    left_tag  = nullptr;
    right_tag = nullptr;
    for (int i = 0; i < 8; ++i) {
        sep_out[i] = (s[i] & 0x80) ? SEP_DOT : SEP_DIM_DOT;
    }
    if (chess) {
        // Nửa Trái [0..3]: d1=1, d3=0 -> MM:SS (hai chấm ':'); d1=1, d3=1 -> SS.cc hoặc -S.cc (một chấm '.', ẩn chấm d3)
        if ((s[1] & 0x80) && !(s[3] & 0x80)) {
            sep_out[1] = SEP_COLON;
            sep_out[3] = SEP_DIM_DOT;
            left_tag   = "MIN : SEC";
        } else if ((s[1] & 0x80) && (s[3] & 0x80)) {
            sep_out[1] = SEP_DOT;
            sep_out[3] = SEP_DIM_DOT;
            left_tag   = "SEC . 1/100";
        }
        // Nửa Phải [4..7]: tương tự trên d5 và d7
        if ((s[5] & 0x80) && !(s[7] & 0x80)) {
            sep_out[5] = SEP_COLON;
            sep_out[7] = SEP_DIM_DOT;
            right_tag  = "MIN : SEC";
        } else if ((s[5] & 0x80) && (s[7] & 0x80)) {
            sep_out[5] = SEP_DOT;
            sep_out[7] = SEP_DIM_DOT;
            right_tag  = "SEC . 1/100";
        }
        return;
    }

    bool dp[8]{};
    for (int i = 0; i < 8; ++i) dp[i] = (s[i] & 0x80) != 0;
    bool is_ampm = (((s[0] & 0x7F) == 0x77 || (s[0] & 0x7F) == 0x73) && (s[1] & 0x7F) == 0x37) ||
                   ((s[0] & 0x7F) == 0x00 && ((s[1] & 0x7F) == 0x77 || (s[1] & 0x7F) == 0x73));

    if (is_ampm) {
        if (dp[3]) sep_out[3] = SEP_COLON;
        if (dp[5]) sep_out[5] = SEP_COLON;
    } else if (st.mode == 1) {
        // ALARM: ALkoHH:MM (dp5)
        if (dp[5] && !dp[1] && !dp[3]) sep_out[5] = SEP_COLON;
    } else if (dp[2] && dp[4] && !dp[1] && !dp[3] && !dp[5]) {
        // STOPWATCH / TIMER live H:MM:SS.mmm hoặc SET HH:MM:SS
        if (dp[0]) sep_out[0] = SEP_COLON;
        sep_out[2] = SEP_COLON;
        sep_out[4] = SEP_DOT;
    } else if (dp[1] && dp[3] && dp[5] && !dp[7]) {
        // TIME 24h+cs: HH:MM:SS.cc
        sep_out[1] = SEP_COLON;
        sep_out[3] = SEP_COLON;
        sep_out[5] = SEP_DOT;
    } else if (dp[3] && dp[5] && !dp[0] && !dp[1] && !dp[7]) {
        // STOPWATCH 99L lap: LL MM:SS.cc hoặc SET page
        sep_out[3] = SEP_COLON;
        sep_out[5] = SEP_DOT;
    }
}

static void draw_h_seg(HDC dc, int x, int y, int w, int t, COLORREF col) {
    int h2 = t / 2;
    POINT pts[6] = {
        {x, y},
        {x + h2, y - h2},
        {x + w - h2, y - h2},
        {x + w, y},
        {x + w - h2, y + h2},
        {x + h2, y + h2},
    };
    HBRUSH br = CreateSolidBrush(col);
    HPEN pn   = CreatePen(PS_SOLID, 1, col);
    HGDIOBJ ob = SelectObject(dc, br);
    HGDIOBJ op = SelectObject(dc, pn);
    Polygon(dc, pts, 6);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(br);
    DeleteObject(pn);
}

static void draw_v_seg(HDC dc, int x, int y, int h, int t, COLORREF col) {
    int h2 = t / 2;
    POINT pts[6] = {
        {x, y},
        {x + h2, y + h2},
        {x + h2, y + h - h2},
        {x, y + h},
        {x - h2, y + h - h2},
        {x - h2, y + h2},
    };
    HBRUSH br = CreateSolidBrush(col);
    HPEN pn   = CreatePen(PS_SOLID, 1, col);
    HGDIOBJ ob = SelectObject(dc, br);
    HGDIOBJ op = SelectObject(dc, pn);
    Polygon(dc, pts, 6);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(br);
    DeleteObject(pn);
}

static void draw_digit(HDC dc, int x, int y, int w, int h, uint8_t pat, SepStyle sep,
                       COLORREF lit_c, COLORREF dim_c) {
    const int t   = 9;
    const int gap = 3;
    int mid_y = y + h / 2;
    int seg_w = w - gap * 2;
    int seg_h = h / 2 - gap * 2;

    // 7 thanh đoạn theo thứ tự chuẩn bit [6:0] = {g, f, e, d, c, b, a}
    draw_h_seg(dc, x + gap, y,         seg_w, t, (pat & 0x01) ? lit_c : dim_c); // a
    draw_v_seg(dc, x + w,   y + gap,   seg_h, t, (pat & 0x02) ? lit_c : dim_c); // b
    draw_v_seg(dc, x + w,   mid_y+gap, seg_h, t, (pat & 0x04) ? lit_c : dim_c); // c
    draw_h_seg(dc, x + gap, y + h,     seg_w, t, (pat & 0x08) ? lit_c : dim_c); // d
    draw_v_seg(dc, x,       mid_y+gap, seg_h, t, (pat & 0x10) ? lit_c : dim_c); // e
    draw_v_seg(dc, x,       y + gap,   seg_h, t, (pat & 0x20) ? lit_c : dim_c); // f
    draw_h_seg(dc, x + gap, mid_y,     seg_w, t, (pat & 0x40) ? lit_c : dim_c); // g

    // Dấu phân cách bên phải chân chữ số: hai chấm dọc (:) hoặc dấu chấm thập phân (.)
    auto fill_dot = [&](int cx, int cy, COLORREF c) {
        HBRUSH br = CreateSolidBrush(c);
        HPEN   pn = CreatePen(PS_SOLID, 1, c);
        HGDIOBJ ob = SelectObject(dc, br);
        HGDIOBJ op = SelectObject(dc, pn);
        Ellipse(dc, cx - 4, cy - 4, cx + 5, cy + 5);
        SelectObject(dc, ob);
        SelectObject(dc, op);
        DeleteObject(br);
        DeleteObject(pn);
    };
    int dot_cx = x + w + 13;
    if (sep == SEP_COLON) {
        fill_dot(dot_cx, y + (h * 32) / 100, lit_c);
        fill_dot(dot_cx, y + (h * 68) / 100, lit_c);
        fill_dot(dot_cx, y + h - 2, dim_c);
    } else {
        fill_dot(dot_cx, y + h - 2, (sep == SEP_DOT) ? lit_c : dim_c);
    }
}

static void render_watch(HDC dc, int w, int h, const FrameState& st) {
    // 1. Nền vỏ đồng hồ màu tối
    RECT full{0, 0, w, h};
    HBRUSH casing = CreateSolidBrush(RGB(22, 26, 35));
    FillRect(dc, &full, casing);
    DeleteObject(casing);

    // 2. Thanh tiêu đề trạng thái phía trên màn LED
    SetBkMode(dc, TRANSPARENT);
    HFONT f_top = CreateFontA(15, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN, "Consolas");
    HGDIOBJ old_f = SelectObject(dc, f_top);
    SetTextColor(dc, RGB(145, 195, 235));
    char hdr[160];
    std::snprintf(hdr, sizeof(hdr),
                  "WatchChip MIPS32 SoC  |  LIVE VERILOG (source + firmware)  |  t=%6.2fs  x%.0f  LED:%s",
                  st.t_ms / 1000.0, st.speed, LED_NAMES[st.color & 3]);
    TextOutA(dc, 26, 12, hdr, static_cast<int>(std::strlen(hdr)));

    if (st.beep) {
        HBRUSH bbr = CreateSolidBrush(RGB(255, 185, 35));
        HPEN   bpn = CreatePen(PS_SOLID, 1, RGB(255, 185, 35));
        HGDIOBJ ob = SelectObject(dc, bbr);
        HGDIOBJ op = SelectObject(dc, bpn);
        RoundRect(dc, w - 92, 9, w - 26, 31, 6, 6);
        SelectObject(dc, ob);
        SelectObject(dc, op);
        DeleteObject(bbr);
        DeleteObject(bpn);
        SetTextColor(dc, RGB(20, 20, 20));
        TextOutA(dc, w - 81, 12, "BEEP!", 5);
    }

    // 3. Khung màn hình 8 LED 7 đoạn (giữa phía trên)
    HBRUSH scr_br = CreateSolidBrush(RGB(10, 13, 18));
    HPEN   scr_pn = CreatePen(PS_SOLID, 2, RGB(52, 62, 78));
    HGDIOBJ ob = SelectObject(dc, scr_br);
    HGDIOBJ op = SelectObject(dc, scr_pn);
    RoundRect(dc, 24, 40, w - 24, 224, 10, 10);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(scr_br);
    DeleteObject(scr_pn);

    const COLORREF lit_c = LED_LIT_COLS[st.color & 3];
    const COLORREF dim_c = LED_DIM_COLS[st.color & 3];
    const bool chess = is_chess_display(st);
    SepStyle seps[8]{};
    const char* left_tag  = nullptr;
    const char* right_tag = nullptr;
    classify_separators(st, chess, seps, left_tag, right_tag);

    const int dig_w  = 52;
    const int dig_h  = 118;
    const int step_x = 84;
    const int start_x = 58;
    const int start_y = 72;

    for (int i = 0; i < 8; ++i) {
        int extra_shift = (chess && i >= 4) ? 10 : ((chess && i < 4) ? -8 : 0);
        draw_digit(dc, start_x + i * step_x + extra_shift, start_y, dig_w, dig_h,
                   st.segs[i], seps[i], lit_c, dim_c);
    }
    if (chess) {
        HPEN sep = CreatePen(PS_SOLID, 2, RGB(58, 70, 88));
        HGDIOBJ os = SelectObject(dc, sep);
        MoveToEx(dc, start_x + 4 * step_x - 10, 56, nullptr);
        LineTo(dc, start_x + 4 * step_x - 10, 206);
        SelectObject(dc, os);
        DeleteObject(sep);

        HFONT f_unit = CreateFontA(13, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                                   DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                   CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN, "Consolas");
        HGDIOBJ ofu = SelectObject(dc, f_unit);
        SetTextColor(dc, RGB(150, 175, 205));
        if (left_tag) {
            RECT lr{40, 48, start_x + 4 * step_x - 18, 65};
            DrawTextA(dc, left_tag, -1, &lr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        }
        if (right_tag) {
            RECT rr{start_x + 4 * step_x - 2, 48, w - 40, 65};
            DrawTextA(dc, right_tag, -1, &rr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        }
        SelectObject(dc, ofu);
        DeleteObject(f_unit);
    }

    // 4. Đường phân cách ngang giữa màn LED và hàng nút bấm (theo phác thảo)
    HPEN div_pn = CreatePen(PS_SOLID, 2, RGB(64, 74, 92));
    HGDIOBJ od = SelectObject(dc, div_pn);
    MoveToEx(dc, 24, 240, nullptr);
    LineTo(dc, w - 24, 240);
    SelectObject(dc, od);
    DeleteObject(div_pn);

    // 5. Bốn nút bấm tròn M, A, B, C ở cạnh dưới
    HFONT f_btn = CreateFontA(26, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, "Segoe UI");
    HFONT f_sub = CreateFontA(13, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, "Segoe UI");

    for (int b = 0; b < 4; ++b) {
        bool down = ((st.btn_down >> b) & 1) != 0;
        int dy = down ? 2 : 0;
        const auto& bt = BUTTONS[b];

        // Vòng viền ngoài nút tròn
        COLORREF rim_c = down ? lit_c : RGB(90, 102, 124);
        COLORREF face_c = down ? RGB(52, 62, 82) : RGB(36, 42, 54);
        HBRUSH fbr = CreateSolidBrush(face_c);
        HPEN   fpn = CreatePen(PS_SOLID, down ? 3 : 2, rim_c);
        HGDIOBJ ob2 = SelectObject(dc, fbr);
        HGDIOBJ op2 = SelectObject(dc, fpn);
        Ellipse(dc, bt.cx - bt.r, bt.cy - bt.r + dy, bt.cx + bt.r, bt.cy + bt.r + dy);
        SelectObject(dc, ob2);
        SelectObject(dc, op2);
        DeleteObject(fbr);
        DeleteObject(fpn);

        // Chữ cái M, A, B, C chính giữa nút tròn
        SelectObject(dc, f_btn);
        SetTextColor(dc, down ? RGB(255, 255, 255) : RGB(225, 232, 244));
        RECT tr{bt.cx - bt.r, bt.cy - bt.r + dy, bt.cx + bt.r, bt.cy + bt.r + dy};
        DrawTextA(dc, bt.key_label, -1, &tr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);

        // Nhãn chức năng nhỏ dưới mỗi nút tròn
        SelectObject(dc, f_sub);
        SetTextColor(dc, RGB(140, 152, 174));
        RECT sr{bt.cx - 56, bt.cy + bt.r + 5, bt.cx + 56, bt.cy + bt.r + 22};
        DrawTextA(dc, bt.sub_label, -1, &sr, DT_CENTER | DT_TOP | DT_SINGLELINE);
    }

    SelectObject(dc, old_f);
    DeleteObject(f_top);
    DeleteObject(f_btn);
    DeleteObject(f_sub);
}

static bool save_capture_bmp(const std::string& path, const FrameState& st) {
    HDC screen = GetDC(nullptr);
    HDC mem    = CreateCompatibleDC(screen);
    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize        = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth       = WIN_W;
    bmi.bmiHeader.biHeight      = WIN_H;   // Bottom-up BMP chuẩn
    bmi.bmiHeader.biPlanes      = 1;
    bmi.bmiHeader.biBitCount    = 24;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    HBITMAP bmp = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!bmp || !bits) {
        if (bmp) DeleteObject(bmp);
        DeleteDC(mem);
        ReleaseDC(nullptr, screen);
        return false;
    }
    HGDIOBJ old = SelectObject(mem, bmp);
    render_watch(mem, WIN_W, WIN_H, st);
    GdiFlush();

    const int stride = ((WIN_W * 3 + 3) / 4) * 4;
    const DWORD img_bytes = static_cast<DWORD>(stride * WIN_H);
    BITMAPFILEHEADER bfh{};
    bfh.bfType    = 0x4D42;
    bfh.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
    bfh.bfSize    = bfh.bfOffBits + img_bytes;

    FILE* fp = std::fopen(path.c_str(), "wb");
    bool ok = false;
    if (fp) {
        std::fwrite(&bfh, sizeof(bfh), 1, fp);
        std::fwrite(&bmi.bmiHeader, sizeof(BITMAPINFOHEADER), 1, fp);
        std::fwrite(bits, img_bytes, 1, fp);
        std::fclose(fp);
        ok = true;
    }
    SelectObject(mem, old);
    DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
    return ok;
}

// ----------------------------------------------------------------------------
// 5. TRẠNG THÁI TOÀN CỤC CHO CỬA SỔ TƯƠNG TÁC & CHẾ ĐỘ HEADLESS (--selftest / --capture)
// ----------------------------------------------------------------------------
static RtlBackend      g_rtl;
static FrameState      g_state;
static std::queue<int> g_key_queue;
static int             g_hold_left   = 0;
static int             g_gap_left    = 0;
static int             g_cur_mask    = 0;
static int             g_mouse_mask  = 0;
static bool            g_prev_beep   = false;
static double          g_speed       = 1.0;

static void tick_simulation(HWND hwnd) {
    if (g_hold_left > 0) {
        --g_hold_left;
        if (g_hold_left == 0) {
            g_cur_mask = 0;
            g_gap_left = GAP_STEPS;
        }
    } else if (g_gap_left > 0) {
        --g_gap_left;
    } else if (!g_key_queue.empty()) {
        int b = g_key_queue.front();
        g_key_queue.pop();
        g_cur_mask  = (1 << b);
        g_hold_left = PRESS_STEPS;
    }

    int eff_mask = g_cur_mask | g_mouse_mask;
    g_state.btn_down = static_cast<uint8_t>(eff_mask);
    g_state.speed    = g_speed;
    if (!g_rtl.step(eff_mask, STEP_MS, g_state)) {
        KillTimer(hwnd, TIMER_ID);
        MessageBoxA(hwnd, "Ket noi voi vvp da ngat.", "WatchChip.exe", MB_ICONERROR);
        PostQuitMessage(1);
        return;
    }
    if (g_state.beep && !g_prev_beep && g_beep_ev) {
        SetEvent(g_beep_ev);
    }
    g_prev_beep = g_state.beep;
    InvalidateRect(hwnd, nullptr, FALSE);
}

static int hit_button(int x, int y) {
    for (int b = 0; b < 4; ++b) {
        int dx = x - BUTTONS[b].cx;
        int dy = y - BUTTONS[b].cy;
        if (dx * dx + dy * dy <= BUTTONS[b].r * BUTTONS[b].r) return b;
    }
    return -1;
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_TIMER:
        if (wp == TIMER_ID) tick_simulation(hwnd);
        return 0;
    case WM_LBUTTONDOWN: {
        int b = hit_button(static_cast<short>(LOWORD(lp)), static_cast<short>(HIWORD(lp)));
        if (b >= 0) {
            g_mouse_mask |= (1 << b);
            g_state.btn_down = static_cast<uint8_t>(g_cur_mask | g_mouse_mask);
            SetCapture(hwnd);
            InvalidateRect(hwnd, nullptr, FALSE);
        }
        return 0;
    }
    case WM_LBUTTONUP:
        if (g_mouse_mask != 0) {
            g_mouse_mask = 0;
            g_state.btn_down = static_cast<uint8_t>(g_cur_mask);
            ReleaseCapture();
            InvalidateRect(hwnd, nullptr, FALSE);
        }
        return 0;
    case WM_KEYDOWN: {
        if (lp & (1 << 30)) return 0; // Bỏ qua auto-repeat khi giữ phím
        int k = static_cast<int>(wp);
        if (k == 'M') g_key_queue.push(0);
        else if (k == 'A') g_key_queue.push(1);
        else if (k == 'B') g_key_queue.push(2);
        else if (k == 'C') g_key_queue.push(3);
        else if (k == '1' || k == '2' || k == '4') {
            g_speed = static_cast<double>(k - '0');
            KillTimer(hwnd, TIMER_ID);
            SetTimer(hwnd, TIMER_ID, std::max(10, static_cast<int>(STEP_MS / g_speed)), nullptr);
            g_state.speed = g_speed;
            InvalidateRect(hwnd, nullptr, FALSE);
        } else if (k == 'Q' || k == VK_ESCAPE) {
            PostMessageA(hwnd, WM_CLOSE, 0, 0);
        }
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps{};
        HDC dc  = BeginPaint(hwnd, &ps);
        HDC mem = CreateCompatibleDC(dc);
        HBITMAP bmp = CreateCompatibleBitmap(dc, WIN_W, WIN_H);
        HGDIOBJ old = SelectObject(mem, bmp);
        render_watch(mem, WIN_W, WIN_H, g_state);
        BitBlt(dc, 0, 0, WIN_W, WIN_H, mem, 0, 0, SRCCOPY);
        SelectObject(mem, old);
        DeleteObject(bmp);
        DeleteDC(mem);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_DESTROY:
        KillTimer(hwnd, TIMER_ID);
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcA(hwnd, msg, wp, lp);
    }
}

static uint64_t pack_segs(const FrameState& s) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | s.segs[i];
    return v;
}

static int run_selftest(const std::string& root, const std::string& report_path) {
    std::string err;
    if (!g_rtl.start(root, err)) {
        if (!report_path.empty()) {
            FILE* fp = std::fopen(report_path.c_str(), "w");
            if (fp) { std::fprintf(fp, "FAIL: %s\n", err.c_str()); std::fclose(fp); }
        }
        return 1;
    }
    FrameState st{};
    auto press = [&](int bit, int ms_after) {
        g_rtl.step(1 << bit, 94, st);
        g_rtl.step(0, ms_after, st);
    };

    g_rtl.step(0, 500, st);
    uint64_t f0 = pack_segs(st);
    int c0 = st.color;
    g_rtl.step(0, 2000, st);
    uint64_t f1 = pack_segs(st);
    press(3, 250); // C: đổi màu LED V_COLOR
    int c1 = st.color;
    press(0, 250); // M -> ALARM
    uint64_t f_alm = pack_segs(st);
    press(0, 250); // M -> STOPWATCH
    uint64_t f_sw0 = pack_segs(st);
    press(1, 200); // A -> START stopwatch
    g_rtl.step(0, 470, st);
    uint64_t f_sw1 = pack_segs(st);
    for (int lap = 0; lap < 10; ++lap) press(2, 120); // B x10: vượt 7 lên cửa sổ trượt 9 Lap
    press(1, 200); // A -> STOP stopwatch
    for (int idx = 0; idx < 8; ++idx) press(3, 180);  // C x8 -> xem Lap 8 (D7 = 0x7F = '8')
    uint8_t lap8_d7 = st.segs[0] & 0x7F;
    press(3, 180);                                     // C x9 -> xem Lap 9 (D7 = 0x6F = '9')
    uint8_t lap9_d7 = st.segs[0] & 0x7F;

    // Kiểm tra hàm vẽ GDI BMP trên RAM không lỗi
    std::string tmp_bmp = root + "\\work\\exe_gdicheck.bmp";
    st.btn_down = 0x4;
    bool bmp_ok = save_capture_bmp(tmp_bmp, st);
    DeleteFileA(tmp_bmp.c_str());
    g_rtl.close();

    bool ok = (f0 != 0ULL) && (f1 != f0) && (c1 == ((c0 + 1) & 3)) &&
              (f_alm != f1) && (f_sw0 != f_alm) && (f_sw1 != f_sw0) &&
              (lap8_d7 == 0x7F) && (lap9_d7 == 0x6F) && bmp_ok;

    if (!report_path.empty()) {
        FILE* fp = std::fopen(report_path.c_str(), "w");
        if (fp) {
            std::fprintf(fp, "%s f0=%llx f1=%llx color=%d->%d alm=%llx sw=%llx->%llx lap8=%02x lap9=%02x bmp=%d\n",
                         ok ? "PASS" : "FAIL",
                         (unsigned long long)f0, (unsigned long long)f1, c0, c1,
                         (unsigned long long)f_alm, (unsigned long long)f_sw0,
                         (unsigned long long)f_sw1, lap8_d7, lap9_d7, bmp_ok ? 1 : 0);
            std::fclose(fp);
        }
    }
    return ok ? 0 : 1;
}

static int run_capture(const std::string& root, const std::string& out_bmp,
                       const std::string& script, int hold_mask) {
    std::string err;
    if (!g_rtl.start(root, err)) return 1;
    FrameState st{};
    std::stringstream ss(script);
    std::string tok;
    while (std::getline(ss, tok, ',')) {
        int m = 0, ms = 0;
        if (std::sscanf(tok.c_str(), "%d:%d", &m, &ms) == 2 && ms > 0) {
            g_rtl.step(m, ms, st);
        }
    }
    st.btn_down = static_cast<uint8_t>(hold_mask & 0xF);
    st.speed    = g_speed;
    bool ok = save_capture_bmp(out_bmp, st);
    g_rtl.close();
    return ok ? 0 : 1;
}

int WINAPI WinMain(HINSTANCE hi, HINSTANCE, LPSTR, int show_cmd) {
    const std::string root = find_repo_root();
    int argc = __argc;
    char** argv = __argv;

    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--selftest") == 0) {
            std::string rep = (i + 1 < argc) ? argv[i + 1] : "";
            return run_selftest(root, rep);
        }
        if (std::strcmp(argv[i], "--capture") == 0 && i + 2 < argc) {
            int hold = (i + 3 < argc) ? std::atoi(argv[i + 3]) : 0;
            return run_capture(root, argv[i + 1], argv[i + 2], hold);
        }
        if (std::strcmp(argv[i], "--speed") == 0 && i + 1 < argc) {
            g_speed = std::max(0.25, std::atof(argv[i + 1]));
            ++i;
        }
    }

    std::string err;
    if (!g_rtl.start(root, err)) {
        MessageBoxA(nullptr, err.c_str(), "WatchChip.exe - Loi khoi dong RTL", MB_ICONERROR);
        return 1;
    }

    g_beep_ev = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    HANDLE h_beep = CreateThread(nullptr, 0, beep_worker, nullptr, 0, nullptr);

    WNDCLASSA wc{};
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = hi;
    wc.hCursor       = LoadCursorA(nullptr, IDC_ARROW);
    wc.lpszClassName = "WatchChipWindowClass";
    RegisterClassA(&wc);

    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT rc{0, 0, WIN_W, WIN_H};
    AdjustWindowRect(&rc, style, FALSE);
    HWND hwnd = CreateWindowA(wc.lpszClassName, "WatchChip.exe", style,
                              CW_USEDEFAULT, CW_USEDEFAULT,
                              rc.right - rc.left, rc.bottom - rc.top,
                              nullptr, nullptr, hi, nullptr);

    g_state.speed = g_speed;
    SetTimer(hwnd, TIMER_ID, std::max(10, static_cast<int>(STEP_MS / g_speed)), nullptr);
    ShowWindow(hwnd, show_cmd);
    UpdateWindow(hwnd);

    MSG msg{};
    while (GetMessageA(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }

    g_beep_quit = true;
    SetEvent(g_beep_ev);
    if (h_beep) {
        WaitForSingleObject(h_beep, 1000);
        CloseHandle(h_beep);
    }
    CloseHandle(g_beep_ev);
    g_rtl.close();
    return static_cast<int>(msg.wParam);
}
