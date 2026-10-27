# -*- coding: utf-8 -*-
"""
forge_desktop.py — 桌面身体的"过隧道"剪刀(2026-09-23)。

把一个很长的桌面 CC 会话裁成"最近 N 轮原文 + 开头一份滚动摘要"的新会话,
然后 `claude --resume <新sid>` 接上。思路来自 Vivi-Seth/forge-reload 和 TG 桥的
Documents\\claude\\tg\\forge_reload.py,但按桌面这边的事实改过:

  * 最近 N 轮只携带她的 channel 消息和发给她的回复正文。
    channel 身体从 companion reply 工具取正文;pbody 身体保留直接回复的 text。
  * thinking / redacted_thinking、内部工具调用和结果、hidden 系统帧不进入新会话。
  * <forge-prep> 那一轮整段剪掉;滚动摘要和便签仍由原有交接流程提供。
  * 原会话不修改;新会话重建 UUID 链,图片保留路径提示。

用法:
  python forge_desktop.py <源.jsonl> <保留轮数> --preview
  python forge_desktop.py <源.jsonl> <保留轮数> [--summary 摘要.md] [--out DIR] [--body channel|pbody]

成功时最后一行打印 NEW_SESSION_ID=<uuid>。非零退出 = 什么都没写。
"""
import argparse
import json
import os
import re
import sys
import tempfile
import uuid

CHANNEL_MARK = '<channel source="companion"'
HUMAN_MARK = 'user="human"'
PREP_MARK = "<forge-prep"
LEGACY_HANDOFF_MARK = "<forge-handoff>"
REPLY_TOOL = "mcp__companion__reply"
META_DENYLIST = ("sourceToolAssistantUUID", "toolUseResult", "leafUuid", "promptId",
                 "session_id", "origin", "promptSource", "queueSkipAttachments")


# ---- read ----------------------------------------------------------------------
def load_events(path):
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise ValueError(f"line {n}: {exc}") from exc
    return out


def _content(e):
    return (e.get("message") or {}).get("content")


def is_channel(e):
    c = _content(e)
    return e.get("type") == "user" and isinstance(c, str) and CHANNEL_MARK in c


def is_human(e):
    return is_channel(e) and HUMAN_MARK in _content(e)


def is_tool_result(e):
    c = _content(e)
    return e.get("type") == "user" and isinstance(c, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in c)


# ---- 1. keep only conversation ------------------------------------------------
def keep_conversation(events):
    kept = []
    for e in events:
        t = e.get("type")
        if t not in ("user", "assistant") or e.get("isSidechain"):
            continue
        if t == "assistant" and (e.get("message") or {}).get("model") == "<synthetic>":
            continue                      # API 失败的占位,不是我说的话
        if t == "user" and not (is_channel(e) or is_tool_result(e)):
            continue                      # 本地命令回显、Stop hook 反馈、图片尺寸注记…
        kept.append(e)
    return kept


def drop_prep_turns(events):
    """剪掉 <forge-prep> 帧和它引出的那一整轮(直到下一条 channel 帧)。
    旧版 swap 的 <forge-handoff> 帧也丢——那是一段聊天原文的复印件,滚动摘要替代它。"""
    out, skipping = [], False
    for e in events:
        if is_channel(e):
            c = _content(e)
            if PREP_MARK in c:
                skipping = True
                continue
            skipping = False
            if LEGACY_HANDOFF_MARK in c:
                continue
        if skipping:
            continue
        out.append(e)
    return out


# ---- 2. cut ---------------------------------------------------------------------
def cut_to_rounds(events, rounds):
    idx = [i for i, e in enumerate(events) if is_human(e)]
    if not idx:
        return []
    return events[0 if len(idx) <= rounds else idx[-rounds]:]


# ---- 3. keep visible dialogue --------------------------------------------------
def dialogue_only(events, reply_mode="channel"):
    """Project transcript protocol onto visible messages, without copying reasoning.

    Keep a marker on projected assistant text so a later Forge preserves it too.
    Channel terminal prose is private; pbody text is delivered as the reply.
    """
    if reply_mode not in ("channel", "pbody"):
        raise ValueError("reply_mode must be channel|pbody")
    failed = set()
    for e in events:
        c = _content(e)
        for b in c if isinstance(c, list) else []:
            if not isinstance(b, dict) or b.get("type") != "tool_result":
                continue
            # MCP errors may be wrapped inside the tool_result content as JSON.
            error = bool(b.get("is_error"))
            value = b.get("content")
            candidates = [value] if isinstance(value, str) else [
                x.get("text", "") for x in value or [] if isinstance(x, dict)]
            for text in candidates:
                try:
                    parsed = json.loads(text)
                except (ValueError, TypeError):
                    continue
                if isinstance(parsed, dict) and parsed.get("isError"):
                    error = True
            if error:
                failed.add(b.get("tool_use_id"))
    stats = {"thinking_kept": 0, "thinking_dropped": 0, "images": 0}
    out = []
    for e in events:
        c = _content(e)
        if is_human(e):
            out.append({**e, "message": {"role": "user", "content": c}})
            continue
        if e.get("type") != "assistant" or not isinstance(c, list):
            continue
        blocks = []
        for b in c:
            if not isinstance(b, dict):
                continue
            t = b.get("type")
            if t in ("thinking", "redacted_thinking"):
                stats["thinking_dropped"] += 1
            elif t == "text" and (reply_mode == "pbody" or e.get("forgeDialogue")):
                text = b.get("text") or ""
                if text.strip() and text.strip() != "[[silent]]":
                    blocks.append({"type": "text", "text": text})
            elif t == "tool_use" and b.get("name") == REPLY_TOOL and b.get("id") not in failed:
                args = b.get("input") or {}
                text = args.get("text") or ""
                if isinstance(text, str) and text.strip():
                    blocks.append({"type": "text", "text": text})
                for path in args.get("images") or []:
                    stats["images"] += 1
                    blocks.append({"type": "text", "text": f"[图片: {path}]"})
        if blocks:
            old = e.get("message") or {}
            msg = {k: old[k] for k in ("id", "model", "type") if k in old}
            msg.update(role="assistant", content=blocks, stop_reason="end_turn")
            out.append({**e, "forgeDialogue": True, "message": msg})
    return out, stats


# ---- 4. summary head + rebuild ---------------------------------------------------
def summary_event(template, text):
    ev = {k: template[k] for k in ("cwd", "entrypoint", "gitBranch", "userType", "version")
          if k in template}
    ev.update({
        "type": "user",
        "isMeta": True,
        "timestamp": template.get("timestamp"),
        "message": {"role": "user", "content": (
            "<forge-summary>\n"
            "(这不是她发来的消息。这是上一段的你在过隧道前亲手更新的滚动摘要——"
            "下面紧接着的是保留的对话正文,不含思考链和内部工具过程。读完直接接着过日子,"
            "一切照旧,别跟她提这份东西,除非她问起。)\n\n"
            f"{text.strip()}\n"
            "</forge-summary>")},
    })
    return ev


def rebuild(events):
    sid = str(uuid.uuid4())
    prev, out = None, []
    for e in events:
        ne = {k: v for k, v in e.items() if k not in META_DENYLIST}
        msg = dict(ne.get("message") or {})
        msg.pop("usage", None)            # 不然 relay 会把旧窗口的用量当成新窗口的
        ne["message"] = msg
        ne.update(isSidechain=False, sessionId=sid, uuid=str(uuid.uuid4()), parentUuid=prev)
        prev = ne["uuid"]
        out.append(ne)
    return sid, out


# ---- token estimate (forge-reload 的校准:CJK≈1/字, ASCII≈3.8 字/token, 每事件 25) --
_CJK = re.compile(r"[⺀-鿿가-힯豈-﫿＀-￯　-〿]")


def _tok(s):
    if not s:
        return 0
    cjk = len(_CJK.findall(s))
    return cjk + int((len(s) - cjk) / 3.8)


def estimate_tokens(events):
    total = 0
    for e in events:
        total += 25
        c = _content(e)
        if isinstance(c, str):
            total += _tok(c)
            continue
        for b in c or []:
            if not isinstance(b, dict):
                continue
            t = b.get("type")
            if t == "text":
                total += _tok(b.get("text"))
            elif t == "thinking":
                total += _tok(b.get("thinking"))
            elif t == "tool_use":
                total += _tok(json.dumps(b.get("input"), ensure_ascii=False))
            elif t == "tool_result":
                rc = b.get("content")
                total += _tok(rc if isinstance(rc, str) else json.dumps(rc, ensure_ascii=False))
    return total


# ---- pipeline --------------------------------------------------------------------
def _peek(e):
    c = _content(e) or ""
    body = re.sub(r"<[^>]+>", "", c).strip().replace("\n", " ")
    return body[:60]


def prepare(source, rounds, summary_text="", strip_thinking=True, *, reply_mode="channel"):
    # Legacy strip_thinking argument is accepted; dialogue-only never carries it.
    if rounds < 1:
        raise ValueError("rounds must be >= 1")
    raw = load_events(source)
    conv = drop_prep_turns(keep_conversation(raw))
    humans_total = sum(1 for e in conv if is_human(e))
    cut = cut_to_rounds(conv, rounds)
    body, st = dialogue_only(cut, reply_mode)
    while body and not is_human(body[0]):
        body.pop(0)
    if not body:
        raise ValueError("no human turn to keep")
    head = [summary_event(body[0], summary_text)] if summary_text.strip() else []
    sid, rebuilt = rebuild(head + body)
    humans = [e for e in rebuilt if is_human(e)]
    stats = {
        "rounds_total": humans_total,
        "rounds_kept": len(humans),
        "events": len(rebuilt),
        "est_tokens": estimate_tokens(rebuilt),
        "summary_chars": len(summary_text.strip()),
        "first_ts": humans[0].get("timestamp") if humans else "",
        "first_msg": _peek(humans[0]) if humans else "",
        "last_msg": _peek(humans[-1]) if humans else "",
        **st,
    }
    return sid, rebuilt, stats


def validate(events, sid, rounds):
    if not events or events[0].get("type") != "user":
        return False, "first event is not user"
    seen, prev, humans = set(), None, 0
    for e in events:
        if e.get("sessionId") != sid:
            return False, "mixed sessionId"
        if e.get("parentUuid") != prev:
            return False, "parentUuid chain break"
        if not e.get("uuid") or e["uuid"] in seen:
            return False, "missing/duplicate uuid"
        seen.add(e["uuid"])
        prev = e["uuid"]
        humans += is_human(e)
        c = _content(e)
        if isinstance(c, list) and any(
            not isinstance(b, dict) or b.get("type") != "text" for b in c
        ):
            return False, "non-dialogue content block"
    if not 1 <= humans <= rounds:
        return False, f"kept {humans} human turns (asked {rounds})"
    return True, "ok"


def write_session(events, sid, out_dir, rounds):
    os.makedirs(out_dir, exist_ok=True)
    final = os.path.join(out_dir, sid + ".jsonl")
    fd, tmp = tempfile.mkstemp(suffix=".jsonl.tmp", dir=out_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            for e in events:
                f.write(json.dumps(e, ensure_ascii=False) + "\n")
        ok, why = validate(load_events(tmp), sid, rounds)
        if not ok:
            raise ValueError("re-validation failed: " + why)
        os.replace(tmp, final)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return final


def forge(source, rounds, out_dir=None, summary_text="", strip_thinking=True, *, reply_mode="channel"):
    """给 relay 调用:成功返回 (new_sid, stats),失败抛异常且什么都没写。"""
    sid, events, stats = prepare(source, rounds, summary_text, strip_thinking, reply_mode=reply_mode)
    ok, why = validate(events, sid, rounds)
    if not ok:
        raise ValueError("structure invalid: " + why)
    write_session(events, sid, out_dir or os.path.dirname(os.path.abspath(source)), rounds)
    return sid, stats


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("rounds", type=int)
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--summary", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--strip-thinking", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--body", choices=("channel", "pbody"), default="channel")
    a = ap.parse_args()
    if a.rounds < 1:
        print("rounds must be >= 1", file=sys.stderr)
        return 2
    summary = open(a.summary, encoding="utf-8").read() if a.summary else ""
    sid, events, stats = prepare(a.source, a.rounds, summary, reply_mode=a.body)
    ok, why = validate(events, sid, a.rounds)
    print(json.dumps({**stats, "valid": ok, "why": why}, ensure_ascii=False, indent=2))
    if not ok:
        return 1
    if a.preview:
        return 0
    path = write_session(events, sid, a.out or os.path.dirname(os.path.abspath(a.source)), a.rounds)
    print("written:", path)
    print("NEW_SESSION_ID=" + sid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
