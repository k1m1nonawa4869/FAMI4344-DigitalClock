# ============================================================================
# HỌC PHẦN:       MI4344 / IT3283 – Kiến trúc Máy tính (HUST - SAMI/SoICT)
# TÊN CÔNG CỤ:    tools/benchmarks/vcd_plot.py — Bộ đọc VCD & Vẽ Dạng Sóng Số Chuẩn Học Thuật
# CHUYÊN ĐỀ KTMT: Chương 04 & 05: Phân tích Đường ống Pipeline, Hazard & Ngoại vi SoC
# VAI TRÒ:        Đọc trực tiếp tệp VCD sinh từ mô phỏng RTL (Icarus Verilog) và kết xuất
#                 biểu đồ dạng sóng số độ phân giải cao (300 DPI) phục vụ Báo cáo & Slide.
# ============================================================================

"""Tiện ích đọc tệp VCD chuẩn IEEE 1364 và vẽ dạng sóng số bằng Matplotlib.

Hỗ trợ cả tín hiệu 1-bit (dạng xung vuông) và bus nhiều bit (thanh hộp kèm giá trị hex),
tô vùng sự kiện nổi bật theo chu kỳ xung nhịp (stall_lu, forwarding, capture 0 ns).
"""
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

NAVY = "#14326E"
CRIMSON = "#B42828"
TEAL = "#0F766E"
AMBER = "#D97706"
SLATE = "#475569"
GRID = "#E2E8F0"


def _norm_bin(raw, width):
    """Chuẩn hóa chuỗi bit VCD thành '0'/'1'/'x'/'z' hoặc chuỗi hex gọn."""
    if raw is None:
        return "x"
    s = raw.lower()
    if len(s) == 1 and width == 1:
        return s
    if "x" in s or "z" in s:
        return "X"
    val = int(s, 2)
    digits = max(1, (width + 3) // 4)
    if width <= 4:
        return f"{val}"
    if digits >= 8:
        return f"{val:0{digits}X}"
    return f"0x{val:0{digits}X}"


def parse_vcd(vcd_path, target_signals, t_max=None):
    """Đọc tệp VCD, trích xuất lịch sử biến thiên cho danh sách tên tín hiệu phân cấp.

    target_signals: danh sách đường dẫn phân cấp đầy đủ (hoặc hậu tố duy nhất),
    ví dụ 'cpu_pipe_tb.clk', 'cpu_pipe_tb.dut.stall_lu'.
    Trả về: (timescale_str, end_time, {signal_key: [(time, raw_val), ...]}).
    """
    scope = []
    id_to_meta = {}
    name_to_id = {}
    in_defs = True
    timescale = "1ps"

    with open(vcd_path, "r", encoding="utf-8", errors="replace") as f:
        lines = iter(f)
        for line in lines:
            s = line.strip()
            if not s:
                continue
            if s.startswith("$timescale"):
                parts = s.split()
                if len(parts) >= 2 and parts[1] != "$end":
                    timescale = parts[1]
                else:
                    for nxt in lines:
                        ns = nxt.strip()
                        if "$end" in ns:
                            tok = ns.replace("$end", "").strip()
                            if tok:
                                timescale = tok
                            break
                        if ns:
                            timescale = ns
            elif s.startswith("$scope"):
                parts = s.split()
                if len(parts) >= 3:
                    scope.append(parts[2])
            elif s.startswith("$upscope"):
                if scope:
                    scope.pop()
            elif s.startswith("$var"):
                m = re.match(r"^\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)(?:\s+\[[^\]]+\])?\s+\$end", s)
                if m:
                    width, vid, vname = int(m.group(1)), m.group(2), m.group(3)
                    full = ".".join(scope + [vname])
                    id_to_meta[vid] = (full, width)
                    name_to_id[full] = vid
            elif s.startswith("$enddefinitions"):
                in_defs = False
                break

        if in_defs:
            raise ValueError(f"VCD thiếu $enddefinitions: {vcd_path}")

        resolved = {}
        wanted_ids = {}
        for tgt in target_signals:
            vid = name_to_id.get(tgt)
            if vid is None:
                matches = [k for k in name_to_id if k.endswith("." + tgt) or k == tgt]
                if len(matches) == 1:
                    vid = name_to_id[matches[0]]
                elif matches:
                    vid = name_to_id[sorted(matches, key=len)[0]]
            if vid is None:
                raise KeyError(f"Không tìm thấy tín hiệu '{tgt}' trong {vcd_path}")
            resolved[tgt] = vid
            wanted_ids.setdefault(vid, []).append(tgt)

        histories = {tgt: [] for tgt in target_signals}
        cur_time = 0
        for line in lines:
            s = line.strip()
            if not s or s.startswith("$dumpvars") or s.startswith("$end") or s.startswith("$comment"):
                continue
            if s[0] == "#":
                cur_time = int(s[1:])
                if t_max is not None and cur_time > t_max:
                    break
                continue
            if s[0] in ("b", "B", "r", "R"):
                val, vid = s[1:].split(None, 1)
            elif s[0] in ("0", "1", "x", "X", "z", "Z"):
                val, vid = s[0], s[1:]
            else:
                continue
            if vid in wanted_ids:
                for tgt in wanted_ids[vid]:
                    hist = histories[tgt]
                    if not hist or hist[-1][1] != val:
                        if hist and hist[-1][0] == cur_time:
                            hist[-1] = (cur_time, val)
                        else:
                            hist.append((cur_time, val))

    widths = {tgt: id_to_meta[resolved[tgt]][1] for tgt in target_signals}
    return timescale, cur_time, widths, histories


def extract_clock_cycles(clk_hist):
    """Tìm danh sách thời điểm sườn lên (posedge '1') của xung clock."""
    edges = []
    prev = None
    for t, v in clk_hist:
        if v == "1" and prev != "1":
            edges.append(t)
        prev = v
    return edges


def sample_at_time(hist, t):
    """Lấy giá trị tại thời điểm t theo giữ mức bậc thang (zero-order hold)."""
    val = None
    for ts, v in hist:
        if ts <= t:
            val = v
        else:
            break
    return val


def render_vcd_waveform(
    vcd_path,
    signals_spec,
    clk_signal,
    cyc_start,
    cyc_end,
    out_png,
    title,
    subtitle="",
    highlights=None,
    bus_formatters=None,
    dpi=300,
):
    """Vẽ biểu đồ dạng sóng RTL thực từ tệp VCD trong cửa sổ chu kỳ [cyc_start, cyc_end].

    signals_spec: [(vcd_path, display_label, color), ...]
    highlights: [(cyc0, cyc1, color, label), ...] vùng tô màu nổi bật theo chỉ số chu kỳ
    bus_formatters: {vcd_path: fn(raw_bin_str, width) -> str}
    """
    bus_formatters = bus_formatters or {}
    highlights = highlights or []
    all_sigs = list(dict.fromkeys([clk_signal] + [s[0] for s in signals_spec]))
    _, end_time, widths, histories = parse_vcd(vcd_path, all_sigs)

    pos_edges = extract_clock_cycles(histories[clk_signal])
    if len(pos_edges) < 3:
        raise RuntimeError(f"Quá ít sườn lên của {clk_signal} trong {vcd_path}")

    cyc_period = pos_edges[1] - pos_edges[0]
    c0 = max(0, cyc_start)
    c1 = min(len(pos_edges) - 1, cyc_end)
    t_win0 = pos_edges[c0] - cyc_period * 0.35
    t_win1 = pos_edges[c1] + cyc_period * 0.65

    def to_cyc_x(t_val):
        return (t_val - pos_edges[0]) / cyc_period

    x0, x1 = to_cyc_x(t_win0), to_cyc_x(t_win1)
    n_rows = len(signals_spec)
    fig_h = max(4.2, 0.56 * n_rows + 1.55)
    fig, ax = plt.subplots(figsize=(11.0, fig_h), dpi=dpi)
    fig.patch.set_facecolor("#FFFFFF")
    ax.set_facecolor("#FAFAFC")

    # Vẽ lưới chu kỳ dọc tại mỗi sườn lên clock
    for c_idx in range(c0, c1 + 1):
        cx = to_cyc_x(pos_edges[c_idx])
        ax.axvline(cx, color=GRID, lw=0.75, ls="--", zorder=0)

    # Tô vùng sự kiện nổi bật (stall / forwarding / 0-ns capture)
    legend_handles = []
    seen_labels = set()
    for hc0, hc1, hcol, hlab in highlights:
        if hc1 < c0 or hc0 > c1:
            continue
        ax.axvspan(hc0 - 0.15, hc1 + 0.85, color=hcol, alpha=0.14, zorder=1)
        if hlab and hlab not in seen_labels:
            seen_labels.add(hlab)
            legend_handles.append(Patch(facecolor=hcol, alpha=0.25, edgecolor=hcol, label=hlab))

    y_ticks, y_labels = [], []
    for idx, (sig, label, color) in enumerate(signals_spec):
        row_center = (n_rows - 1 - idx) * 1.15
        y_ticks.append(row_center + 0.35)
        y_labels.append(label)
        hist = histories[sig]
        w = widths[sig]

        # Cắt các đoạn ổn định nằm trong [t_win0, t_win1]
        init_val = sample_at_time(hist, t_win0)
        pts = [(t_win0, init_val)]
        for ts, v in hist:
            if t_win0 < ts < t_win1:
                pts.append((ts, v))
        pts.append((t_win1, pts[-1][1]))

        if w == 1:
            xs = [to_cyc_x(t) for t, _ in pts]
            ys = []
            for _, v in pts:
                if v == "1":
                    ys.append(row_center + 0.68)
                elif v == "0":
                    ys.append(row_center + 0.04)
                else:
                    ys.append(row_center + 0.36)
            ax.step(xs, ys, where="post", color=color, lw=1.7, zorder=3)
            ax.fill_between(
                xs,
                row_center + 0.04,
                ys,
                step="post",
                color=color,
                alpha=0.13,
                zorder=2,
            )
        else:
            for k in range(len(pts) - 1):
                ta, va = pts[k]
                tb, _ = pts[k + 1]
                xa, xb = to_cyc_x(ta), to_cyc_x(tb)
                if xb - xa <= 1e-6:
                    continue
                is_x = va is None or "x" in va.lower() or "z" in va.lower()
                box_col = "#CBD5E1" if is_x else color
                fill_col = "#F1F5F9" if is_x else color
                fill_alpha = 0.6 if is_x else 0.11
                ax.fill_between(
                    [xa, xb],
                    row_center + 0.04,
                    row_center + 0.68,
                    color=fill_col,
                    alpha=fill_alpha,
                    zorder=2,
                )
                ax.plot([xa, xb], [row_center + 0.68, row_center + 0.68], color=box_col, lw=1.25, zorder=3)
                ax.plot([xa, xb], [row_center + 0.04, row_center + 0.04], color=box_col, lw=1.25, zorder=3)
                ax.plot([xa, xa], [row_center + 0.04, row_center + 0.68], color=box_col, lw=1.0, zorder=3)
                fmt_fn = bus_formatters.get(sig)
                txt = fmt_fn(va, w) if fmt_fn else _norm_bin(va, w)
                span = xb - xa
                if span >= 0.65 and txt:
                    max_chars = max(4, int(span * 9.5))
                    if len(txt) > max_chars:
                        txt = txt[: max_chars - 1] + "…"
                    ax.text(
                        0.5 * (xa + xb),
                        row_center + 0.36,
                        txt,
                        ha="center",
                        va="center",
                        fontsize=6.6 if len(txt) >= 8 else 7.3,
                        fontfamily="DejaVu Sans Mono",
                        color="#0F172A" if not is_x else SLATE,
                        zorder=4,
                    )

    ax.set_yticks(y_ticks)
    ax.set_yticklabels(y_labels, fontsize=8.5, fontfamily="DejaVu Sans", fontweight="bold", color="#0F172A")
    ax.set_xlim(x0, x1)
    ax.set_ylim(-0.35, (n_rows - 1) * 1.15 + 1.05)

    step = 1 if (c1 - c0) <= 22 else max(2, (c1 - c0) // 14)
    ticks = list(range(c0, c1 + 1, step))
    ax.set_xticks(ticks)
    ax.set_xticklabels([f"c{t}" for t in ticks], fontsize=8, color=SLATE)
    ax.set_xlabel(
        f"Chu kỳ xung nhịp hệ thống (T_clk = {cyc_period * 1e-3:.0f} ns @ 50 MHz) — trích trực tiếp từ {vcd_path.replace(chr(92), '/')}",
        fontsize=8.5,
        color=SLATE,
        labelpad=6,
    )

    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    ax.spines["left"].set_color("#CBD5E1")
    ax.spines["bottom"].set_color("#CBD5E1")

    ax.set_title(title, loc="left", fontsize=11, fontweight="bold", color=NAVY, pad=18 if subtitle else 10)
    if subtitle:
        ax.text(0.0, 1.015, subtitle, transform=ax.transAxes, fontsize=8.3, color=SLATE, va="bottom")
    if legend_handles:
        ax.legend(handles=legend_handles, loc="upper right", fontsize=8, frameon=True, facecolor="#FFFFFF", edgecolor=GRID)

    fig.tight_layout()
    fig.savefig(out_png, dpi=dpi)
    plt.close(fig)
