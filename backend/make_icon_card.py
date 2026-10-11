# make_icon_card.py — 一次性:从"自带圆角卡片+投影"的图标设计稿里抠出白色卡片本体,
# 出 PWA 三件套(iOS 会自己再裁圆角,所以喂给它的必须是铺满边缘的方图)
# 用法: .venv\Scripts\python.exe make_icon_card.py [源图路径]
import sys
from pathlib import Path

from PIL import Image

SRC = Path(sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\sxc\Pictures\白.jpg")
WEB = Path(__file__).parent.parent / "web"

img = Image.open(SRC).convert("RGB")
w, h = img.size

# 白色卡片(≈250+)比灰底(≈235)亮:阈值二值化后取亮区外接框
gray = img.convert("L")
mask = gray.point(lambda p: 255 if p >= 246 else 0)
bbox = mask.getbbox()

if bbox and (bbox[2] - bbox[0]) < w * 0.95:
    # 往里收 2%,避开卡片自身的圆角边缘和底部投影
    bw, bh = bbox[2] - bbox[0], bbox[3] - bbox[1]
    inset_x, inset_y = int(bw * 0.02), int(bh * 0.02)
    left, top = bbox[0] + inset_x, bbox[1] + inset_y
    right, bottom = bbox[2] - inset_x, bbox[3] - inset_y
    print(f"card detected: {bbox} -> crop ({left},{top},{right},{bottom})")
else:
    # 检测失败(整图都亮):退回中央 56% 裁切
    side = int(min(w, h) * 0.56)
    left, top = (w - side) // 2, (h - side) // 2
    right, bottom = left + side, top + side
    print(f"card not detected, fallback center crop ({left},{top},{right},{bottom})")

# 取裁切区的中央正方形
cw, ch = right - left, bottom - top
side = min(cw, ch)
cx, cy = left + cw // 2, top + ch // 2
img = img.crop((cx - side // 2, cy - side // 2, cx - side // 2 + side, cy - side // 2 + side))

for name, size in (("icon-512.png", 512), ("icon-192.png", 192), ("apple-touch-icon.png", 180)):
    img.resize((size, size), Image.LANCZOS).save(WEB / name, "PNG")
    print(f"{name} <- {size}x{size} ok")
print("done — 重装 PWA 后生效(图标是安装时定格的)")
