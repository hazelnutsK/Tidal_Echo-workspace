# make_icons.py — 一次性:把小雪挑的图裁方缩成 PWA 三件套图标
# 用法: .venv\Scripts\python.exe make_icons.py [源图路径] [缩放,默认1.0]
#   缩放<1 = 主体整体缩小,四周用图片角落的底色补边(图标嫌大时用,如 0.78)
import sys
from pathlib import Path

from PIL import Image

SRC = Path(sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\sxc\Pictures\咪.jpg")
SCALE = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
WEB = Path(__file__).parent.parent / "web"

img = Image.open(SRC).convert("RGB")
w, h = img.size
side = min(w, h)
left, top = (w - side) // 2, (h - side) // 2
img = img.crop((left, top, left + side, top + side))

if 0 < SCALE < 1:
    inner = img.resize((int(side * SCALE),) * 2, Image.LANCZOS)
    canvas = Image.new("RGB", (side, side), img.getpixel((3, 3)))  # 角落色当底
    off = (side - inner.width) // 2
    canvas.paste(inner, (off, off))
    img = canvas
    print(f"scaled to {SCALE:.2f}, padded with corner color {img.getpixel((3, 3))}")

for name, size in (("icon-512.png", 512), ("icon-192.png", 192), ("apple-touch-icon.png", 180)):
    out = WEB / name
    img.resize((size, size), Image.LANCZOS).save(out, "PNG")
    print(f"{name} <- {size}x{size} ok")
print("done — sw 的 PRECACHE 缓存名单里这些文件名没变,bump CACHE 后手机会重新拉")
