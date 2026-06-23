#!/usr/bin/env python3
"""
生成极简风 1Panel Client iOS App 图标 (1024x1024 PNG)
纯标准库实现（zlib + struct），不依赖 Pillow。

设计：
- 深海军蓝背景 (#0A2540)
- 中央白色圆角方形描边
- 圆角方形内：粗体数字 "1" + 横向分割线（暗示「面板/服务器」）
- 整张图标充满 1024x1024 画布，无透明、无圆角（iOS 自动裁剪）
"""
import zlib
import struct
import math
import os

SIZE = 1024
# 颜色（sRGB 8 位）
BG = (10, 37, 64)        # #0A2540 深海军蓝
FG = (255, 255, 255)     # 纯白

def lerp(a, b, t):
    return a + (b - a) * t

def blend(fg, bg, alpha):
    """alpha 合成 fg over bg"""
    return tuple(int(lerp(bg[i], fg[i], alpha)) for i in range(3))

def aa_coverage(x, x0, x1):
    """一维区间 [x0,x1] 对像素 [x, x+1) 的覆盖比例（0..1），用于抗锯齿"""
    left = max(x, x0)
    right = min(x + 1, x1)
    return max(0.0, min(1.0, right - left))

def round_rect_coverage(px, py, rect_x, rect_y, rect_w, rect_h, radius):
    """点 (px+0.5, py+0.5) 落在圆角矩形内/外的覆盖率（带抗锯齿边界）。
    这里返回内/外布尔近似 + 边缘 1px 软化用。"""
    # 简化：返回 1.0（内部）或 0.0（外部），边缘用距离函数做软化
    cx0, cy0 = rect_x, rect_y
    cx1, cy1 = rect_x + rect_w, rect_y + rect_h
    # 先判断在哪个角区域
    # 内部矩形（去掉圆角）
    ix0, iy0 = cx0 + radius, cy0 + radius
    ix1, iy1 = cx1 - radius, cy1 - radius
    # 中心点
    x = px + 0.5
    y = py + 0.5
    # 计算到内部矩形的有符号距离
    dx = 0.0
    if x < ix0: dx = x - ix0
    elif x > ix1: dx = x - ix1
    dy = 0.0
    if y < iy0: dy = y - iy0
    elif y > iy1: dy = y - iy1
    if dx == 0 and dy == 0:
        return 1.0
    if dx == 0:
        # 仅 y 方向在外，距离 = |dy|，但仍在圆角矩形内（因为 dx==0 在侧边）
        return 1.0 if (cx0 <= x <= cx1 and cy0 <= y <= cy1) else 0.0
    if dy == 0:
        return 1.0 if (cx0 <= x <= cx1 and cy0 <= y <= cy1) else 0.0
    # 在角区域，计算到对应圆心的距离
    d = math.sqrt(dx * dx + dy * dy)
    # 边界在 d == radius 处
    # 抗锯齿：边界 ±0.5 像素过渡
    cov = radius - d
    cov = max(0.0, min(1.0, cov + 0.5))
    return cov

def stroke_coverage(px, py, rect_x, rect_y, rect_w, rect_h, radius, stroke_w):
    """圆角描边的覆盖率：在 [inner, outer] 环带内为 1"""
    outer = round_rect_coverage(px, py, rect_x, rect_y, rect_w, rect_h, radius)
    inner = round_rect_coverage(px, py,
                                rect_x + stroke_w, rect_y + stroke_w,
                                rect_w - 2 * stroke_w, rect_h - 2 * stroke_w,
                                max(0, radius - stroke_w))
    return max(0.0, outer - inner)

def rect_filled_coverage(px, py, x0, y0, x1, y1):
    """实心矩形覆盖率（带抗锯齿）"""
    cx = aa_coverage(px, x0, x1)
    cy = aa_coverage(py, y0, y1)
    return cx * cy

def build_pixel_buffer():
    """构建 sRGB 像素缓冲区，返回 bytes（每像素 3 字节 RGB）"""
    buf = bytearray(SIZE * SIZE * 3)
    # 预填背景色
    for i in range(SIZE * SIZE):
        buf[i * 3] = BG[0]
        buf[i * 3 + 1] = BG[1]
        buf[i * 3 + 2] = BG[2]

    # ============ 设计参数 ============
    # 外圆角方形（白色描边）
    margin = 230
    outer_x = margin
    outer_y = margin
    outer_w = SIZE - 2 * margin
    outer_h = SIZE - 2 * margin
    outer_radius = 150
    stroke_w = 26  # 描边粗细

    # 数字 "1" 的竖线（粗）
    # "1" 由一个左侧斜短杠 + 主竖线 + 底部横杠组成，简化为主竖线 + 底座
    bar_w = 90          # 竖线宽度
    bar_h = 400         # 竖线高度
    bar_x = (SIZE - bar_w) // 2 + 25  # 略偏右（数字 1 的视觉重心）
    bar_y = (SIZE - bar_h) // 2 - 50

    # 底座横杠（让 1 有「底座」，更像数字 1）
    base_w = 200
    base_h = 32
    base_x = (SIZE - base_w) // 2 + 25
    base_y = bar_y + bar_h - base_h + 15

    # 左侧小斜杠（数字 1 的左上角装饰）- 用旋转 45 度近似
    slash_w = 30
    slash_h = 100
    slash_x = bar_x - 80
    slash_y = bar_y + 20

    # 分割线（暗示服务器/面板分层）—— 位于底座下方
    div_w = outer_w - 2 * 110
    div_h = 10
    div_x = outer_x + 110
    div_y = base_y + base_h + 70  # 在底座下方

    # ============ 渲染 ============
    for py in range(SIZE):
        # 只在可能有内容的行做精细计算，加速
        row_progress = py / SIZE
        for px in range(SIZE):
            alpha = 0.0
            # 1) 外圆角描边
            a = stroke_coverage(px, py, outer_x, outer_y, outer_w, outer_h,
                                outer_radius, stroke_w)
            if a > alpha: alpha = a
            # 2) 竖线
            a = rect_filled_coverage(px, py, bar_x, bar_y, bar_x + bar_w, bar_y + bar_h)
            if a > alpha: alpha = a
            # 3) 底座
            a = rect_filled_coverage(px, py, base_x, base_y, base_x + base_w, base_y + base_h)
            if a > alpha: alpha = a
            # 4) 左上斜杠（简化为矩形，不旋转，避免计算复杂）
            a = rect_filled_coverage(px, py, slash_x, slash_y, slash_x + slash_w, slash_y + slash_h)
            if a > alpha: alpha = a
            # 5) 底部分割线
            a = rect_filled_coverage(px, py, div_x, div_y, div_x + div_w, div_y + div_h)
            if a > alpha: alpha = a
            if alpha > 0.001:
                idx = (py * SIZE + px) * 3
                c = blend(FG, BG, alpha)
                buf[idx] = c[0]
                buf[idx + 1] = c[1]
                buf[idx + 2] = c[2]
        # 进度（每 100 行打印一次，stderr）
        if py % 200 == 0:
            import sys
            print(f"  row {py}/{SIZE}", file=sys.stderr, end='\r')
    print("")
    return bytes(buf)

def write_png(path, width, height, rgb_bytes):
    """手写 PNG（不依赖 Pillow）"""
    def chunk(typ, data):
        c = typ + data
        crc = zlib.crc32(c) & 0xffffffff
        return struct.pack('>I', len(data)) + c + struct.pack('>I', crc)

    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)  # 8-bit, color type 2 (RGB)
    # 每行前加 filter byte 0
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw.extend(rgb_bytes[y * stride:(y + 1) * stride])
    idat = zlib.compress(bytes(raw), 9)
    png = sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)

def main():
    out = os.path.join(os.path.dirname(__file__), '..', 'app-icon-1024.png')
    out = os.path.abspath(out)
    print(f"Generating {SIZE}x{SIZE} icon...")
    buf = build_pixel_buffer()
    write_png(out, SIZE, SIZE, buf)
    size_kb = os.path.getsize(out) / 1024
    print(f"Wrote {out} ({size_kb:.1f} KB)")

if __name__ == '__main__':
    main()
