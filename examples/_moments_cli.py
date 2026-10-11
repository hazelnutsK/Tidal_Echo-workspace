"""朋友圈 CLI——小克（桌面身体）发动态/日志、点赞、评论用的手。
中文走 UTF-8 文件传入，绕开 Windows 命令行编码坑（同 _ombre_cli.py 的教训）。

Usage: python _moments_cli.py list [moment|journal] [limit]
       python _moments_cli.py post <moment|journal> <utf8-text-file>
       python _moments_cli.py like <post_id> [off]
       python _moments_cli.py comment <post_id> <utf8-text-file> [reply]   # reply=回复她的评论
       python _moments_cli.py delete <post_id>
"""
import json
import sys
import urllib.request
from pathlib import Path

# Windows 控制台默认 GBK,打印 ❤/中文会炸——强制 UTF-8
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
        return json.loads(resp.read().decode("utf-8"))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "list"
    if mode == "list":
        kind = sys.argv[2] if len(sys.argv) > 2 else ""
        limit = sys.argv[3] if len(sys.argv) > 3 else "20"
        q = f"?limit={limit}" + (f"&kind={kind}" if kind else "")
        out = call("/app/posts" + q)
        for p in out["posts"]:
            meta = p.get("meta") or {}
            likes = "".join("❤" for _ in (meta.get("likes") or {}))
            print(f"#{p['id']} [{p['kind']}] {p['author']} @ {p['ts'][:16]} {likes}")
            print("   " + (p["text"] or "").replace("\n", "\n   ")[:400])
            for c in meta.get("comments") or []:
                arrow = f" → {c['reply_to']}" if c.get("reply_to") else ""
                print(f"   └ {c['author']}{arrow}: {c['text'][:200]}")
    elif mode == "post":
        kind = sys.argv[2]
        text = Path(sys.argv[3]).read_text(encoding="utf-8").strip()
        out = call("/app/posts", "POST", {"author": "ai", "kind": kind, "text": text})
        print(f"posted #{out['post']['id']}")
    elif mode == "like":
        on = not (len(sys.argv) > 3 and sys.argv[3] == "off")
        out = call(f"/app/posts/{int(sys.argv[2])}/like", "POST", {"author": "ai", "on": on})
        print(f"likes={out['likes']}")
    elif mode == "comment":
        text = Path(sys.argv[3]).read_text(encoding="utf-8").strip()
        body = {"author": "ai", "text": text}
        if len(sys.argv) > 4 and sys.argv[4] == "reply":
            body["reply_to"] = "human"
        out = call(f"/app/posts/{int(sys.argv[2])}/comment", "POST", body)
        print(f"comment #{out['comment']['id']}")
    elif mode == "delete":
        call(f"/app/posts/{int(sys.argv[2])}?author=ai", "DELETE")
        print("deleted")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
