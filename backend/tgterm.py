# -*- coding: utf-8 -*-
r"""tgterm — 把 CC 会话的 transcript 重建成"终端画面"喂给 mini app。

两个身体：
  bridge  = TG 桥（Documents\claude\tg，无窗 CC）——它 90% 在聊天，主菜是 thinking
  desktop = 桌面身体（这台机器上干活的那个）——工具流密集，才是真"终端"

桥没有 TTY，没有 ANSI 字节流可截，所以这里做的是**从 transcript 重建**，
不是镜像一块真屏幕。分辨率上限就是 jsonl 里有什么。

纯函数 + 只读文件，不导入 app.py，可以单独跑：python tgterm.py
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

# --- 两个身体的坐标 ---------------------------------------------------------
HOME = Path.home()
BRIDGE_DIR = Path(os.environ.get("TGTERM_BRIDGE_DIR", str(HOME / "Documents" / "claude" / "tg")))
BRIDGE_PROJECT_DIR = Path(os.environ.get(
    "TGTERM_BRIDGE_PROJECT_DIR",
    str(HOME / ".claude" / "projects" / "C--Users-sxc-Documents-claude-tg"),
))
BRIDGE_CMD_FILE = BRIDGE_DIR / "tg-bridge-headless.cmd"
BRIDGE_SID_FILE = BRIDGE_DIR / ".bridge-sid"

# 冷启动时从文件尾部回溯多少字节（2.5MB 的 jsonl 不能整个读给手机）
COLD_TAIL_BYTES = int(os.environ.get("TGTERM_COLD_TAIL_BYTES", str(192 * 1024)))
# 单条 tool_result 吐给前端的上限（实测最大一条 131KB，是一次 Read 大文件）
RESULT_MAX_CHARS = int(os.environ.get("TGTERM_RESULT_MAX_CHARS", "1800"))
# 单次响应最多回多少个事件，防止久未轮询后一次灌爆
MAX_EVENTS = int(os.environ.get("TGTERM_MAX_EVENTS", "400"))

_CHANNEL_RE = re.compile(r'<channel\s+([^>]*)>\s*(.*?)\s*</channel>', re.S)
_ATTR_RE = re.compile(r'(\w+)="([^"]*)"')
# 桥会话独有的指纹：她的消息以 telegram channel 标签存进 user 事件
_BRIDGE_MARKER = '"content":"<channel source=\\"plugin:telegram:telegram\\"'
# relay 注入的系统帧（她看不到这些，所以画面上也不该记在她账上）
_SYS_FRAME_RE = re.compile(
    r'^<(desire-pulse|night-watch|calendar-remind|calendar-created|timer-event|ask-event'
    r'|moments-event|reading-event|garden-wake)\b', re.I)


# ---------------------------------------------------------------------------
# 会话定位
# ---------------------------------------------------------------------------

def _bridge_transcript() -> Path | None:
    """桥当前会话。先信 .bridge-sid（启动时写的），文件没了再按 marker 兜底。"""
    try:
        sid = BRIDGE_SID_FILE.read_text(encoding="utf-8", errors="replace").strip()
        if sid:
            p = BRIDGE_PROJECT_DIR / f"{sid}.jsonl"
            if p.is_file():
                return p
    except OSError:
        pass
    # 兜底：目录里含 telegram 指纹的最新一个（该目录混着她另开的 CC 写的文件）
    try:
        cands = []
        for p in BRIDGE_PROJECT_DIR.glob("*.jsonl"):
            if not p.is_file():
                continue
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as fh:
                    if _BRIDGE_MARKER in fh.read(65536):
                        cands.append(p)
            except OSError:
                continue
        return max(cands, key=lambda p: p.stat().st_mtime) if cands else None
    except OSError:
        return None


def bridge_model() -> str:
    """桥跑在什么模型上 —— 唯一真源是启动 cmd 里硬编码的 --model。"""
    try:
        for line in BRIDGE_CMD_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r'^\s*claude .*--model\s+(\S+)', line)
            if m:
                return m.group(1)
    except OSError:
        pass
    return "unknown"


def window_for(model: str, observed_ctx: int = 0, authoritative: bool = False) -> int:
    """[1m] 是唯一合法的窗口后缀（别的后缀 CLI 静默接受然后每条消息都失败）。

    ⚠️ transcript 里的 message.model 是**裸名**（"claude-opus-5"，没有 [1m]），
    所以光看它会把 1M 会话当成 200k —— 2026-08-22 我就这么把 companion 身体的
    19.5% 报成了 97.7%,虚惊一场。裸名必须去配置链里补后缀,别拿占用反推:
    "超过 200k 才算 1M" 在 150k~200k 这段恰好判错,而且错的方向是虚报快爆了。
    实测反推只留作配置全读不到时的最后兜底。

    authoritative=True 表示这个名字来自启动 cmd 的 --model（桥就是这样）——
    那是完整写法,没后缀就是真的 200k,**不能**再去问全局 settings:桥有自己的
    settings,拿 desktop 的配置去套它会把 opus-4-6 说成 1M。
    """
    if "[1m]" in (model or ""):
        return 1000000
    if not authoritative and model and not model.startswith("<"):
        cfg = configured_model()          # 裸名 -> 去 settings 链问后缀
        if cfg and "[1m]" in cfg:
            return 1000000
    return 1000000 if observed_ctx > 200000 else 200000


# desktop/companion 身体没有 --model 可读,模型来自 settings 链:
# --settings 指定的那份优先,没写 model 就落到全局 ~/.claude/settings.json。
CC_SETTINGS_FILE = Path(os.environ.get(
    "TGTERM_CC_SETTINGS", str(Path(__file__).parent / "cc-settings.json")))
GLOBAL_SETTINGS_FILE = HOME / ".claude" / "settings.json"


def configured_model() -> str:
    for p in (CC_SETTINGS_FILE, GLOBAL_SETTINGS_FILE):
        try:
            m = json.loads(p.read_text(encoding="utf-8")).get("model")
        except (OSError, ValueError):
            continue
        if m:
            return str(m)
    return ""


def model_from_transcript(path: Path | None) -> str:
    """desktop 身体没有启动 cmd 可读，只能问 transcript 最近一条 assistant。"""
    if not path or not path.is_file():
        return "unknown"
    try:
        size = path.stat().st_size
        with open(path, "rb") as fh:
            fh.seek(max(0, size - 256 * 1024))
            lines = fh.read().split(b"\n")
        for raw in reversed(lines):
            if b'"model"' not in raw:
                continue
            try:
                m = (json.loads(raw).get("message") or {}).get("model") or ""
            except Exception:
                continue
            # 失败的 API 调用会记成 <synthetic> 占位，别把它当成模型名
            if m and not m.startswith("<"):
                return m
    except OSError:
        pass
    return "unknown"


# ---------------------------------------------------------------------------
# 一行 jsonl -> 若干终端事件
# ---------------------------------------------------------------------------

def _text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                parts.append(b.get("text") or "")
            elif isinstance(b, str):
                parts.append(b)
        return "\n".join(parts)
    return ""


def _clip(s: str, limit: int) -> tuple[str, int]:
    """截断长文本，返回 (可显示部分, 被省掉的行数)。"""
    s = s or ""
    if len(s) <= limit:
        return s, 0
    head = s[:limit]
    hidden = s[limit:].count("\n") + 1
    return head, hidden


def _tool_brief(name: str, inp) -> str:
    """工具调用那一行括号里显示什么 —— 决定终端好不好看。"""
    if not isinstance(inp, dict):
        return ""
    short = (name or "").split("__")[-1]
    for key in ("command", "file_path", "pattern", "path", "url", "query", "prompt"):
        if inp.get(key):
            v = str(inp[key]).replace("\n", " ").strip()
            if key == "file_path":
                v = v.replace(str(HOME), "~")
            return v[:160]
    # MCP reply / 发消息类：显示要发出去的话
    if inp.get("text"):
        return str(inp["text"]).replace("\n", " ").strip()[:160]
    try:
        return json.dumps(inp, ensure_ascii=False)[:120]
    except Exception:
        return ""


def parse_line(raw: bytes) -> list[dict]:
    """一行 jsonl -> 事件列表。看不懂的行安静跳过。"""
    try:
        d = json.loads(raw)
    except Exception:
        return []
    if not isinstance(d, dict) or d.get("isSidechain"):
        return []

    typ = d.get("type")
    ts = str(d.get("timestamp") or "")
    msg = d.get("message") or {}
    content = msg.get("content")
    out: list[dict] = []

    if typ == "user":
        # 她的话可能裹在 <channel> 里；工具结果也走 user 事件
        blocks = content if isinstance(content, list) else []
        for b in blocks:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                c = b.get("content")
                body = c if isinstance(c, str) else _text_of(c)
                if not body:
                    try:
                        body = json.dumps(c, ensure_ascii=False)
                    except Exception:
                        body = ""
                shown, hidden = _clip(body, RESULT_MAX_CHARS)
                out.append({
                    "t": "tool_result", "ts": ts, "text": shown, "hidden": hidden,
                    "is_error": bool(b.get("is_error")),
                    "tool_use_id": b.get("tool_use_id") or "",
                })
        if not out:
            s = _text_of(content)
            m = _CHANNEL_RE.search(s)
            if m:
                attrs = dict(_ATTR_RE.findall(m.group(1)))
                body = m.group(2).strip()
                if "image_path" in attrs:
                    body = ("[图片] " + body).strip()
                # 系统帧也是裹在 <channel> 里送进来的（desire-pulse/night-watch/
                # timer-event…），它们不是她说的话 —— 渲染成她的发言会误导。
                kind = "system" if _SYS_FRAME_RE.match(body) else "user"
                out.append({"t": kind, "ts": ts, "text": body,
                            "source": attrs.get("source", "")})
            elif s.strip():
                # 系统注入帧（desire-pulse / calendar-remind / 读书帧…）也照实显示
                kind = "system" if s.lstrip().startswith("<") else "user"
                out.append({"t": kind, "ts": ts, "text": s.strip()[:2000]})

    elif typ == "assistant":
        model = msg.get("model") or ""
        usage = msg.get("usage") or {}
        for b in (content if isinstance(content, list) else []):
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "thinking":
                tx = (b.get("thinking") or "").strip()
                if tx:
                    out.append({"t": "thinking", "ts": ts, "text": tx, "model": model})
            elif bt == "text":
                tx = (b.get("text") or "").strip()
                if tx:
                    out.append({"t": "assistant", "ts": ts, "text": tx, "model": model})
            elif bt == "tool_use":
                name = b.get("name") or ""
                inp = b.get("input")
                ev = {
                    "t": "tool_use", "ts": ts, "name": name,
                    "brief": _tool_brief(name, inp),
                    "id": b.get("id") or "", "model": model,
                }
                # 发消息类工具（MCP reply / sendMessage）：那不是"调用参数"，
                # 那是他说出口的话，前端要当消息渲染，所以给全文而不是截断的 brief
                if isinstance(inp, dict) and inp.get("text") and "reply" in name.lower():
                    ev["said"] = str(inp["text"])[:4000]
                out.append(ev)
        if usage and out:
            ctx = (int(usage.get("input_tokens") or 0)
                   + int(usage.get("cache_read_input_tokens") or 0)
                   + int(usage.get("cache_creation_input_tokens") or 0))
            out[-1]["ctx"] = ctx
    return out


# ---------------------------------------------------------------------------
# 尾读
# ---------------------------------------------------------------------------

def resolve(body: str, desktop_transcript=None) -> Path | None:
    if body == "bridge":
        return _bridge_transcript()
    return desktop_transcript


def _read_from(path: Path, start: int, size: int, drop_first: bool) -> tuple[list[dict], int]:
    """读 [start, size) 并解析成事件。只吃到最后一个完整换行 —— CC 正在写的时候
    读到半截尾行是常态，剩下的留给下一拍。"""
    with open(path, "rb") as fh:
        fh.seek(start)
        chunk = fh.read(size - start)
    nl = chunk.rfind(b"\n")
    if nl < 0:
        return [], start
    lines = chunk[:nl].split(b"\n")
    if drop_first and start > 0 and lines:
        lines = lines[1:]        # 回溯起点多半落在半行中间，丢掉它
    events: list[dict] = []
    for raw in lines:
        if raw.strip():
            events.extend(parse_line(raw))
    return events, start + nl + 1


def tail(path: Path, after: int = -1, want_events: int = 60) -> dict:
    """after<0 = 冷启动（从尾部回溯）；否则从该字节偏移续读。

    冷启动是自适应的：desktop 身体一轮对话能刷几百 KB 工具输出，固定窗口会
    把"她说了什么"挤到画面外，只剩没头没尾的工具流。所以事件不够就把回溯
    窗口翻倍，直到攒够一屏或够到文件头。
    """
    size = path.stat().st_size
    cold = after < 0 or after > size      # after>size = 文件被换掉了（forge/换模型）

    if not cold:
        events, consumed = _read_from(path, after, size, drop_first=False)
    else:
        span = COLD_TAIL_BYTES
        events, consumed = [], size
        while True:
            start = max(0, size - span)
            events, consumed = _read_from(path, start, size, drop_first=True)
            # 光"够一屏"不算数：一段纯工具流也能轻松刷满一屏，却看不到这一切
            # 因何而起。要求画面里至少有一句她的话（或一帧系统消息）当锚点。
            anchored = any(e["t"] in ("user", "system") for e in events)
            if (len(events) >= want_events and anchored) or start == 0 \
                    or span >= COLD_TAIL_BYTES * 16:
                break
            span *= 2

    dropped = len(events) > MAX_EVENTS
    if dropped:
        events = events[-MAX_EVENTS:]
    return {"offset": consumed, "size": size, "events": events, "dropped": dropped}


def status(path: Path | None, model: str, authoritative: bool = False) -> dict:
    """状态栏：模型 + 上下文占用。算法与 ctx-handler.ps1 一致（尾部最近一条 usage）。"""
    ctx = 0
    if path and path.is_file():
        try:
            size = path.stat().st_size
            with open(path, "rb") as fh:
                fh.seek(max(0, size - 256 * 1024))
                lines = fh.read().split(b"\n")
            for raw in reversed(lines):
                if b'"usage"' not in raw:
                    continue
                try:
                    u = (json.loads(raw).get("message") or {}).get("usage") or {}
                except Exception:
                    continue
                if u:
                    ctx = (int(u.get("input_tokens") or 0)
                           + int(u.get("cache_read_input_tokens") or 0)
                           + int(u.get("cache_creation_input_tokens") or 0))
                    break
        except OSError:
            pass
    limit = window_for(model, ctx, authoritative)
    return {
        "model": model,
        "ctx": ctx,
        "limit": limit,
        "pct": round(ctx / limit * 100, 1) if limit else 0.0,
        "sid": path.stem if path else "",
    }


# ---------------------------------------------------------------------------
# 控制 —— 把她本来要在 TG 里打字的自助命令做成按钮
#
# 这里**不调那几个 hook 脚本**：它们守着 CLAUDE_TG_BRIDGE=1、要从 stdin 吃一份
# hook payload、而且会自己给她发 TG 消息。所以复刻决策逻辑,只共用它们那条
# 经过验证的重启链。
#
# ⚠️ 起进程一律走 WMI Win32_Process.Create —— 进程由 WMI 服务创建,不继承
#    relay 的环境。从 CC 会话里直接 spawn 会把 CLAUDE_CODE_* 传下去,那个
#    claude 会认为自己是别人的子会话,**完全不写 transcript**(2026-07-25 血案,
#    她丢了 45 分钟对话)。
# ---------------------------------------------------------------------------

# 演习闸:默认只报告"会做什么",不真动手。她验过界面再在 relay.env 里放开。
CONTROL_ARMED = os.environ.get("TGTERM_CONTROL_ARMED", "0") == "1"

THINK_STATE = BRIDGE_DIR / "hooks" / ".think-display"
RELAUNCH_STAMP = BRIDGE_DIR / ".last-relaunch"
FORGE_POINTER = BRIDGE_DIR / "forge-next.sid"
APPLY_MODEL = BRIDGE_DIR / "hooks" / "apply-model.ps1"
FORGE_SCRIPT = BRIDGE_DIR / "forge_reload.py"

MODEL_ALIAS = {
    "opus5": "claude-opus-5", "opus": "claude-opus-5",
    "opus48": "claude-opus-4-8", "opus46": "claude-opus-4-6",
    "fable": "claude-fable-5[1m]", "fable5": "claude-fable-5[1m]",
    "sonnet": "claude-sonnet-5", "sonnet5": "claude-sonnet-5",
    "haiku": "claude-haiku-4-5-20251001",
}
MODEL_FULL = ["claude-opus-5", "claude-opus-4-8", "claude-opus-4-6",
              "claude-fable-5", "claude-sonnet-5", "claude-haiku-4-5-20251001"]


def resolve_model(arg: str) -> str:
    """别名/全名 -> 真正写进 --model 的字符串。认不出返回 ""。

    白名单不是洁癖:打错的模型名 CLI 会照常启动,然后每条消息都失败,
    她那边只看到他不回话(2026-07-18 的 [200k] 事故就是这样)。
    """
    key = (arg or "").strip().lower()
    if key in MODEL_ALIAS:
        return MODEL_ALIAS[key]
    base = re.sub(r"\[1m\]$", "", key)
    if base in MODEL_FULL:
        return base + "[1m]" if key.endswith("[1m]") else base
    return ""


def think_state() -> str:
    """默认开着:那个文件只有在她翻过一次开关之后才存在。"""
    try:
        return "off" if THINK_STATE.read_text(encoding="utf-8").strip().lower() == "off" else "on"
    except OSError:
        return "on"


def _run_detached(ps_script: str) -> None:
    """用 WMI 起一条脱离 relay 的命令链。EncodedCommand 避开引号转义地狱。"""
    import base64
    import subprocess
    enc = base64.b64encode(ps_script.encode("utf-16-le")).decode("ascii")
    subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", enc],
        capture_output=True, timeout=30,
    )


def _chain(extra: str = "") -> str:
    """杀桥树 -> [extra] -> 清重启戳 -> 让计划任务在干净环境里把它拉回来。

    删 .last-relaunch 是必须的:watchdog 在一次重启后 180s 内不做健康检查,
    人为杀桥后若留着旧戳,它会对刚被杀掉的桥撒手不管,没人拉它起来。
    """
    # ⚠️ 命令行里带 "带引号的路径",所以 PS 侧必须用**单引号**字面量拼接:
    #    双引号字符串会在路径那对引号处提前收尾,链子从中间断开 —— 后果是
    #    taskkill 照跑而 relaunch 不跑,桥死了爬不回来。
    mid = f" & {extra}" if extra else ""
    literal = (
        mid
        + f' & del /q "{RELAUNCH_STAMP}"'
        + " & ping -n 3 127.0.0.1 >nul"
        + " & schtasks /Run /TN ClaudeTelegramBridge"
    )
    if "'" in literal:                     # 单引号会破坏 PS 字面量,宁可不跑
        raise ValueError("restart chain contains a single quote: " + literal)
    return (
        "$b = Get-CimInstance Win32_Process -Filter \"Name='claude.exe'\" | "
        "Where-Object { $_.CommandLine -match '--channels' } | Select-Object -First 1; "
        "if (-not $b) { exit 1 }; "
        "$t = $b.ParentProcessId; if (-not $t) { $t = $b.ProcessId }; "
        "$c = 'cmd.exe /c ping -n 3 127.0.0.1 >nul & taskkill /F /T /PID ' "
        f"+ $t + '{literal}'; "
        "Invoke-CimMethod -ClassName Win32_Process -MethodName Create "
        "-Arguments @{ CommandLine = $c } | Out-Null"
    )


def _write_pointer(sid: str) -> None:
    """一次性 resume 指针。换行有没有都能被 cmd 的 set /p 读出来(2026-08-22 实测
    三种写法都行),这里跟 model-handler 保持一致带 CRLF。"""
    FORGE_POINTER.write_text(sid + "\r\n", encoding="ascii")


def control(action: str, value: str = "", confirmed: bool = False) -> dict:
    """按钮的后端。危险档必须带 confirmed=True 才真动手。"""
    action = (action or "").strip()

    # ── 安全档:只碰一个状态文件,不重启任何东西 ──
    if action == "think":
        cur = think_state()
        nxt = "off" if cur == "on" else "on"
        THINK_STATE.parent.mkdir(parents=True, exist_ok=True)
        THINK_STATE.write_text(nxt, encoding="ascii")
        return {"applied": True, "state": nxt,
                "message": f"思考显示{'开了' if nxt == 'on' else '关了'}"
                           "（思考一直在跑,这只管发不发给你看）"}

    if action == "think_state":
        return {"state": think_state()}

    # ── 危险档:先说清楚会发生什么 ──
    if action == "model":
        target = resolve_model(value)
        if not target:
            return {"error": f"不认识 “{value}”,没敢换。可用:"
                             + " / ".join(MODEL_ALIAS.keys())}
        cur = bridge_model()
        if target == cur:
            return {"message": f"已经跑在 {cur} 了,不用换。"}
        if not confirmed:
            return {"needs_confirm": True,
                    "effect": f"{cur}\n  ↓\n{target}\n\n上下文原地保留（--resume）",
                    "note": "会杀掉桥再拉起来,十几秒内他收不到 TG 消息。"}
        p = _bridge_transcript()
        if not p:
            return {"error": "找不到当前会话,没敢动。"}
        if not CONTROL_ARMED:
            return {"applied": False, "dry_run": True,
                    "message": f"演习:会把 {cur} 换成 {target}（保 {p.stem[:8]}）。"
                               "真要生效,relay.env 里设 TGTERM_CONTROL_ARMED=1"}
        _write_pointer(p.stem)
        _run_detached(_chain(
            f'powershell -NoProfile -ExecutionPolicy Bypass -File "{APPLY_MODEL}" {target}'))
        return {"applied": True, "message": f"切到 {target},十几秒后回来。"}

    if action == "forge":
        try:
            retain = max(5, min(int(value or 25), 400))
        except ValueError:
            return {"error": "轮数得是个数字。"}
        if not confirmed:
            return {"needs_confirm": True,
                    "effect": f"裁掉旧对话,只保留最近 {retain} 轮\n换到一个新会话继续",
                    "note": "裁掉的部分他就真的不记得了 —— 重要的先存进记忆库。"}
        p = _bridge_transcript()
        if not p:
            return {"error": "找不到当前会话,没敢动。"}
        if not CONTROL_ARMED:
            return {"applied": False, "dry_run": True,
                    "message": f"演习:会把 {p.stem[:8]} 裁到最近 {retain} 轮。"
                               "真要生效,relay.env 里设 TGTERM_CONTROL_ARMED=1"}
        import subprocess
        out = subprocess.run(
            ["python", str(FORGE_SCRIPT), str(p), str(retain), "--out", str(BRIDGE_PROJECT_DIR)],
            capture_output=True, text=True, timeout=180,
        )
        m = re.search(r"NEW_SESSION_ID=([0-9a-fA-F-]{36})", out.stdout or "")
        if not m:
            tail_err = ((out.stdout or "") + (out.stderr or "")).strip().splitlines()
            return {"error": "锻造失败,会话没动。" + (tail_err[-1] if tail_err else "")}
        new_sid = m.group(1)
        _write_pointer(new_sid)
        _run_detached(_chain())
        return {"applied": True, "message": f"锻造完成（新会话 {new_sid[:8]}）,正在切过去。"}

    if action == "reset":
        if not confirmed:
            return {"needs_confirm": True,
                    "effect": "丢掉全部上下文,开一个白板会话",
                    "note": "这个不可逆 —— 他会完全不记得你们聊过什么。"}
        if not CONTROL_ARMED:
            return {"applied": False, "dry_run": True,
                    "message": "演习:会把桥重置成空会话。"
                               "真要生效,relay.env 里设 TGTERM_CONTROL_ARMED=1"}
        try:
            FORGE_POINTER.unlink()      # 有残留指针的话会被 --resume 回去
        except OSError:
            pass
        _run_detached(_chain())
        return {"applied": True, "message": "重置了,几十秒后是一个全新的他。"}

    return {"error": f"不认识的动作:{action}"}


if __name__ == "__main__":   # 冒烟自测：python tgterm.py
    import sys
    which = sys.argv[1] if len(sys.argv) > 1 else "bridge"
    if which == "bridge":
        p, mdl = _bridge_transcript(), bridge_model()
    else:
        # 自测用最新 jsonl 近似 desktop；relay 里走 active_transcript()（更准）
        d = HOME / ".claude" / "projects" / "C--Users-sxc"
        fs = [x for x in d.glob("*.jsonl") if x.is_file()]
        p = max(fs, key=lambda x: x.stat().st_mtime) if fs else None
        mdl = model_from_transcript(p)
    print("transcript:", p)
    if not p:
        raise SystemExit("找不到会话文件")
    print("status:", json.dumps(status(p, mdl), ensure_ascii=False))
    r = tail(p, -1)
    print(f"events={len(r['events'])} offset={r['offset']} size={r['size']}")
    from collections import Counter
    print("kinds:", dict(Counter(e["t"] for e in r["events"])))
    for e in r["events"][-12:]:
        head = (e.get("text") or e.get("brief") or "")[:70].replace("\n", " ")
        print(f"  [{e['t']:11}] {head}")
