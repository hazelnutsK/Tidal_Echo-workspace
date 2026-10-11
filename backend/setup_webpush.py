# setup_webpush.py — 一次性:生成 VAPID 钥匙对 + 写进 relay.env(幂等,重跑不换钥匙)
# 用法: .venv\Scripts\python.exe setup_webpush.py
from pathlib import Path
import re

from cryptography.hazmat.primitives import serialization
from py_vapid import Vapid02
from py_vapid.utils import b64urlencode

HERE = Path(__file__).parent
PRIV = HERE / "vapid_private.pem"
ENV = HERE / "relay.env"
SUBJECT = "mailto:hazelkirii@gmail.com"

# 私钥:已有就复用(换钥匙会让手机上已有的订阅全部失效,别乱重生成)
if PRIV.exists():
    v = Vapid02.from_file(str(PRIV))
    print(f"reuse existing key: {PRIV.name}")
else:
    v = Vapid02()
    v.generate_keys()
    v.save_key(str(PRIV))
    print(f"generated new key: {PRIV.name}")

# 浏览器要的 applicationServerKey = 未压缩 EC 公钥点的 base64url
raw = v.public_key.public_bytes(
    serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
)
pub = b64urlencode(raw)


def set_line(text: str, key: str, val: str) -> str:
    if re.search(rf"^{re.escape(key)}=", text, re.M):
        # 替换串用 lambda,不然 Windows 路径里的 \U 会被当成 regex 转义炸掉
        return re.sub(rf"^{re.escape(key)}=.*$", lambda _m: f"{key}={val}", text, flags=re.M)
    return text.rstrip("\n") + f"\n{key}={val}\n"


text = ENV.read_text(encoding="utf-8") if ENV.exists() else ""
text = set_line(text, "VAPID_PUBLIC_KEY", pub)
text = set_line(text, "VAPID_PRIVATE_PEM", str(PRIV))
text = set_line(text, "VAPID_SUBJECT", SUBJECT)
ENV.write_text(text, encoding="utf-8")

print(f"VAPID_PUBLIC_KEY={pub}")
print(f"written into {ENV.name} — 重启 relay 后生效")
