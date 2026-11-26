# -*- coding: utf-8 -*-
"""passbook 应用图标生成器 —— 唯一真源。

设计（「纸与墨」，颜色全部取自 app/lib/theme/app_theme.dart 的 Palette）：
    ｜ 一枚安静的本子该有的样子：纸白底、一枚盖上去的赤陶印章，印里一枚墨色钥匙孔。
    ｜
    ｜ 底   纸白 #F8F6F1，圆角方形（半径 22%），一道 1.2% 宽的墨色描边（22% 墨）
    ｜ 主体 赤陶方印 #A4553C，占画布 60%，几乎直角（边长 4% 的圆角）
    ｜ 印中 墨色钥匙孔 #1B1A17
    ｜
    ｜ 描边不是装饰：纸白在浅色桌面/任务栏上会与背景糊在一起，墨线编码「边界」。
    ｜ 除它之外不加任何东西——阴影、渐变、高光都编码不出信息。

小尺寸分级（不是偷懒，是 16px 上画钥匙孔只会得到一撮脏像素）：
    ≥48  完整：圆头 + 收窄茎
    32    简化：圆头更大、茎更短更粗
    ≤24   只留赤陶色块——识别靠色块与位置，不靠细节

用法：
    python3 branding/make_icons.py            # 生成全部产物
    python3 branding/make_icons.py --preview  # 只出预览图

产物：
    windows/runner/resources/app_icon.ico                     16–256 七档
    android/app/src/main/res/mipmap-*/ic_launcher.png         48–192 五档
    android/app/src/main/res/mipmap-*/ic_launcher_foreground.png  108–432 五档（自适应前景）
    android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml    自适应声明
    android/app/src/main/res/values/ic_launcher_background.xml    自适应背景色
    branding/passbook-1024.png                                母图（存档/对外用）
    branding/preview-sizes.png                                各尺寸对比预览（人眼复核用）
"""
from __future__ import annotations

import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# ── 调色板（与 app_theme.dart 的 Palette 逐字一致） ────────────────────────────
PAPER = (0xF8, 0xF6, 0xF1, 255)  # Palette.paper
INK = (0x1B, 0x1A, 0x17, 255)  # Palette.ink
SEAL = (0xA4, 0x55, 0x3C, 255)  # Palette.seal

# ── 几何（全部是画布边长的比例，改这里就改设计） ──────────────────────────────
SS = 4  # 超采样倍数，降采样时抗锯齿
CORNER = 0.22  # 圆角方形底的半径
HAIRLINE = 0.012  # 墨色描边宽度
HAIRLINE_ALPHA = 56  # 22% 墨：看得见边界，抢不了主体
STAMP_TRAD = 0.54  # 传统图标的印章边长（留白够，印章才像盖上去的而不是填满的）
# 自适应前景的印章边长：圆形遮罩的安全区是 72/108dp，约束的是**对角线**，
# 所以方形印章上限 = 72/√2/108 ≈ 0.47。取 0.45 留一线余量。
STAMP_ADAPTIVE = 0.45
STAMP_CORNER = 0.075  # 印章圆角：纸底 22% 圆润 / 印章 7.5% 正直，这组对比就是设计语言

KEYHOLE_D = 0.34  # 钥匙孔圆头直径 / 印章边长
KEYHOLE_STEM_W = 0.46  # 茎宽 / 圆头直径
KEYHOLE_STEM_H = 0.82  # 茎高 / 圆头直径（1:1.8 的修长比例才读得出「锁孔」）
KEYHOLE_TAPER = 0.86  # 茎底宽 / 茎顶宽
# 简化档
KEYHOLE_D_SMALL = 0.40
KEYHOLE_STEM_W_SMALL = 0.54
KEYHOLE_STEM_H_SMALL = 0.55


def _rgba(color: tuple[int, int, int, int], alpha: int | None = None):
    if alpha is None:
        return color
    return (color[0], color[1], color[2], alpha)


def _keyhole(d: ImageDraw.ImageDraw, cx: float, top: float, dia: float,
             stem_w_ratio: float, stem_h_ratio: float, color) -> None:
    """在 (cx, top) 处画一枚钥匙孔：圆头在上，收窄的茎在下。"""
    stem_w = dia * stem_w_ratio
    stem_h = dia * stem_h_ratio
    # 圆头
    d.ellipse([cx - dia / 2, top, cx + dia / 2, top + dia], fill=color)
    # 茎（梯形，向下略收窄）
    y0 = top + dia * 0.72  # 与圆头重叠一点，避免接缝
    y1 = top + dia + stem_h
    w0 = stem_w / 2
    w1 = w0 * KEYHOLE_TAPER
    d.polygon(
        [(cx - w0, y0), (cx + w0, y0), (cx + w1, y1), (cx - w1, y1)],
        fill=color,
    )


def draw_icon(size: int, *, adaptive_foreground: bool = False) -> Image.Image:
    """按目标尺寸从头绘制（不靠大图缩放），返回 RGBA 图。"""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    if not adaptive_foreground:
        # 纸底 + 墨色发丝描边
        r = CORNER * s
        w = max(1, round(HAIRLINE * s))
        inset = w / 2
        d.rounded_rectangle(
            [inset, inset, s - 1 - inset, s - 1 - inset],
            radius=r,
            fill=PAPER,
            outline=_rgba(INK, HAIRLINE_ALPHA),
            width=w,
        )

    # 赤陶印章
    p = (STAMP_ADAPTIVE if adaptive_foreground else STAMP_TRAD) * s
    cx = cy = s / 2
    x0, y0 = cx - p / 2, cy - p / 2
    d.rounded_rectangle(
        [x0, y0, x0 + p, y0 + p], radius=STAMP_CORNER * p, fill=SEAL
    )

    # 印中钥匙孔：按印章边长分级
    if size >= 48:
        dia = KEYHOLE_D * p
        stem_w, stem_h = KEYHOLE_STEM_W, KEYHOLE_STEM_H
    elif size >= 32:
        dia = KEYHOLE_D_SMALL * p
        stem_w, stem_h = KEYHOLE_STEM_W_SMALL, KEYHOLE_STEM_H_SMALL
    else:
        dia = 0.0

    if dia > 0:
        total_h = dia + dia * stem_h
        top = cy - total_h / 2
        _keyhole(d, cx, top, dia, stem_w, stem_h, INK)

    return img.resize((size, size), Image.LANCZOS)


def save_ico(path: Path, sizes: list[int]) -> None:
    """自己拼 ICO 容器：每个尺寸独立绘制（分级），而不是让 PIL 从大图缩。

    每个条目内嵌 PNG（Vista+ 支持，Windows 10/11 全部可用）。
    """
    frames: list[bytes] = []
    for sz in sizes:
        buf = io.BytesIO()
        draw_icon(sz).save(buf, format="PNG", optimize=True)
        frames.append(buf.getvalue())

    n = len(sizes)
    header = struct.pack("<HHH", 0, 1, n)  # reserved, type=icon, count
    offset = 6 + 16 * n
    entries = bytearray()
    for sz, data in zip(sizes, frames):
        dim = 0 if sz >= 256 else sz  # 256 在目录项里记 0
        entries += struct.pack(
            "<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset
        )
        offset += len(data)
    path.write_bytes(header + bytes(entries) + b"".join(frames))


def write_preview(out: Path) -> None:
    """各尺寸对比预览：上半浅底、下半深底，检查两种环境下的可辨性。"""
    sizes = [16, 24, 32, 48, 64, 128, 256]
    pad, gap = 16, 12
    band_h = max(sizes) + pad * 2
    width = pad * 2 + sum(sizes) + gap * (len(sizes) - 1) + 260
    canvas = Image.new("RGBA", (width, band_h * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    d.rectangle([0, 0, width, band_h], fill=(0xFA, 0xFA, 0xFA, 255))
    d.rectangle([0, band_h, width, band_h * 2], fill=(0x20, 0x20, 0x20, 255))

    for band in range(2):
        x = pad
        base_y = band * band_h + pad
        for sz in sizes:
            icon = draw_icon(sz)
            canvas.alpha_composite(icon, (x, base_y + (max(sizes) - sz) // 2))
            d.text(
                (x, band * band_h + band_h - pad - 8),
                f"{sz}",
                fill=(0x66, 0x66, 0x66, 255) if band == 0 else (0xAA, 0xAA, 0xAA, 255),
            )
            x += sz + gap
        # 自适应前景预览（108dp 画布，裁成圆形看效果）
        fx = x + 24
        fg = draw_icon(192, adaptive_foreground=True)
        bg = Image.new("RGBA", (192, 192), PAPER)
        bg.alpha_composite(fg)
        mask = Image.new("L", (192, 192), 0)
        ImageDraw.Draw(mask).ellipse([0, 0, 191, 191], fill=255)
        circle = Image.new("RGBA", (192, 192), (0, 0, 0, 0))
        circle.paste(bg, (0, 0), mask)
        canvas.alpha_composite(circle, (fx, base_y + (max(sizes) - 192) // 2))
        d.text(
            (fx, band * band_h + band_h - pad - 8),
            "adaptive(circle)",
            fill=(0x66, 0x66, 0x66, 255) if band == 0 else (0xAA, 0xAA, 0xAA, 255),
        )

    canvas.convert("RGB").save(out, format="PNG", optimize=True)


ANDROID_TRAD = {  # 传统图标：密度 -> 边长
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}
ANDROID_ADAPTIVE = {  # 自适应前景：108dp 画布
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}

ADAPTIVE_XML = """\
<?xml version="1.0" encoding="utf-8"?>
<!-- passbook 自适应图标（Android 8+）。背景是纸白纯色，前景是赤陶印章。
     内容落在中央 72/108dp 安全区内，圆形/方圆/圆角方遮罩下都不会被裁到印章。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""

BACKGROUND_XML = """\
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Palette.paper -->
    <color name="ic_launcher_background">#F8F6F1</color>
</resources>
"""


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parents[1]  # passbook/
    app = root / "app"
    branding = root / "branding"
    branding.mkdir(exist_ok=True)

    preview_only = "--preview" in argv

    if not preview_only:
        # 母图
        draw_icon(1024).save(branding / "passbook-1024.png", format="PNG", optimize=True)
        print(f"[ok] {branding / 'passbook-1024.png'}")

        # Windows
        ico = app / "windows" / "runner" / "resources" / "app_icon.ico"
        save_ico(ico, [16, 24, 32, 48, 64, 128, 256])
        print(f"[ok] {ico}  ({ico.stat().st_size:,} B)")

        # Android 传统
        for density, sz in ANDROID_TRAD.items():
            dst = app / "android" / "app" / "src" / "main" / "res" / f"mipmap-{density}" / "ic_launcher.png"
            dst.parent.mkdir(parents=True, exist_ok=True)
            draw_icon(sz).save(dst, format="PNG", optimize=True)
            print(f"[ok] {dst}  ({sz}px)")

        # Android 自适应前景
        for density, sz in ANDROID_ADAPTIVE.items():
            dst = app / "android" / "app" / "src" / "main" / "res" / f"mipmap-{density}" / "ic_launcher_foreground.png"
            dst.parent.mkdir(parents=True, exist_ok=True)
            draw_icon(sz, adaptive_foreground=True).save(dst, format="PNG", optimize=True)
            print(f"[ok] {dst}  ({sz}px)")

        # Android 自适应声明 + 背景色
        anydpi = app / "android" / "app" / "src" / "main" / "res" / "mipmap-anydpi-v26"
        anydpi.mkdir(parents=True, exist_ok=True)
        (anydpi / "ic_launcher.xml").write_text(ADAPTIVE_XML, encoding="utf-8", newline="\n")
        print(f"[ok] {anydpi / 'ic_launcher.xml'}")

        vals = app / "android" / "app" / "src" / "main" / "res" / "values"
        (vals / "ic_launcher_background.xml").write_text(BACKGROUND_XML, encoding="utf-8", newline="\n")
        print(f"[ok] {vals / 'ic_launcher_background.xml'}")

    preview = branding / "preview-sizes.png"
    write_preview(preview)
    print(f"[ok] {preview}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
