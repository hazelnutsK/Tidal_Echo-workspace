"""相册 CLI——小克（桌面身体）管自己那本相册的手。

日常收藏走回复里的标记 [[keep:标题|想说的话]]（收最近那张照片）。
这个 CLI 是补收/改字/取下用的：翻旧照片、想起来该写点什么、或者收错了。
中文一律走 UTF-8 文件传入，别在命令行里内联（Windows 编码坑）。

Usage: python _album_cli.py list [limit]
       python _album_cli.py candidates [limit]              # 最近聊天里的照片,标出收没收过
       python _album_cli.py keep <url|#src_id> <utf8-file>  # 文件第一行=标题,其余=想说的话
       python _album_cli.py edit <album_id> <utf8-file>     # 同上,改标题/评语
       python _album_cli.py drop <album_id>                 # 取下(照片本体还在聊天里)
"""
import json
import sys
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

BASE = "http://127.0.0.1:3011/relay"
ENV_PATH = Path(__file__).resolve().parent.parent / "backend" / "relay.env"


def secret() -> str:
    for line in ENV_PATH.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("RELAY_SECRET="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("RELAY_SECRET not found in relay.env")


def call(path: str, method: str = "GET", body=None):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"Authorization": "Bearer " + secret(), "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw) if raw else {}


def read_words(path: str):
    """文件第一行是标题，空行之后（或第二行起）是想说的话。"""
    lines = Path(path).read_text(encoding="utf-8").strip().splitlines()
    title = lines[0].strip() if lines else ""
    note = "\n".join(lines[1:]).strip()
    return title, note


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "list"
    if mode == "list":
        limit = sys.argv[2] if len(sys.argv) > 2 else "50"
        for p in call(f"/app/album?limit={limit}")["photos"]:
            print(f"#{p['id']} {p['ts'][:16]}  {p['title'] or '(无题)'}")
            print(f"   {p['url']}")
            if p["note"]:
                print("   " + p["note"].replace("\n", "\n   ")[:500])
    elif mode == "candidates":
        limit = sys.argv[2] if len(sys.argv) > 2 else "20"
        for p in call(f"/app/album/ai/candidates?limit={limit}")["photos"]:
            mark = "✔收过" if p["kept"] else "     "
            print(f"{mark} #{p['src_id']} {p['ts'][:16]} [{p['from']}] {p['url']}")
    elif mode == "keep":
        ref = sys.argv[2]
        title, note = read_words(sys.argv[3])
        body = {"title": title, "note": note}
        if ref.startswith("#"):
            body["src_id"] = int(ref[1:])
        else:
            body["url"] = ref
        print("kept #%s" % call("/app/album/ai/keep", "POST", body)["id"])
    elif mode == "edit":
        title, note = read_words(sys.argv[3])
        call(f"/app/album/ai/{int(sys.argv[2])}", "POST", {"title": title, "note": note})
        print("updated #" + sys.argv[2])
    elif mode == "drop":
        out = call(f"/app/album/ai/{int(sys.argv[2])}", "DELETE")
        print("removed" if out.get("removed") else "not found")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
