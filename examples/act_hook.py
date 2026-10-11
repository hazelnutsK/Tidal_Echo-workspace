"""CC PostToolUse hook——把桌面身体的工具调用变成手机上的 act 小扳手条。
只在 RELAY_ACT_FEED=1 的 CC 会话里生效（channel 身体的启动环境带这个，
小雪电脑上手动开的终端 CC 不带,不会把干活刷进她聊天）。
永不阻塞、永不报错——钩子挂了不能影响正事。
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

RELAY = "http://127.0.0.1:3011/relay/channel/out"
ENV_PATH = Path(r"C:\Users\sxc\Tidal_Echo\backend\relay.env")

# 只报有戏剧性的工具；Read/Grep/Edit 这类幕后杂活不上台
SKIP_PREFIX = ("mcp__companion",)   # reply/react 本身就是消息,不当工具报
ALLOW = {"Bash", "WebSearch", "WebFetch"}
ALLOW_PREFIX = ("mcp__ombre",)

MEMORY_PREFIX = "mcp__ombre"


def main() -> None:
    if os.environ.get("RELAY_ACT_FEED") != "1":
        return
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    tool = str(data.get("tool_name") or "")
    if not tool or any(tool.startswith(p) for p in SKIP_PREFIX):
        return
    if tool not in ALLOW and not any(tool.startswith(p) for p in ALLOW_PREFIX):
        return

    short = tool.rsplit("__", 1)[-1]
    if tool.startswith(MEMORY_PREFIX):
        glyph, verb = "memory", "翻了翻记忆"
    elif tool in ("WebSearch", "WebFetch"):
        glyph, verb = "terminal", "出门看了看"
    else:
        glyph, verb = "terminal", "用了工具"

    try:
        cmd = json.dumps(data.get("tool_input") or {}, ensure_ascii=False)
    except Exception:
        cmd = str(data.get("tool_input"))
    resp = data.get("tool_response")
    try:
        result = resp if isinstance(resp, str) else json.dumps(resp, ensure_ascii=False)
    except Exception:
        result = str(resp)
    result = " ".join((result or "").split())
    payload = {
        "type": "act", "glyph": glyph,
        "text": f"{verb} · {short}",
        "steps": [{"tool": short, "cmd": cmd[:160] + ("…" if len(cmd) > 160 else ""),
                   "result": result[:240] + ("…" if len(result) > 240 else "")}],
    }

    try:
        secret = next(l.split("=", 1)[1].strip()
                      for l in ENV_PATH.read_text(encoding="utf-8").splitlines()
                      if l.startswith("RELAY_SECRET="))
        req = urllib.request.Request(
            RELAY, data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Authorization": "Bearer " + secret, "Content-Type": "application/json"},
            method="POST")
        urllib.request.urlopen(req, timeout=5).read()
    except Exception:
        pass   # relay 没起/超时——静默,别拖累工具调用


if __name__ == "__main__":
    main()
