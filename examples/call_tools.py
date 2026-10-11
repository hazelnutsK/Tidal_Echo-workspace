"""Session-scoped outgoing calls; previews never ring a device."""
from contextvars import ContextVar
import json
import uuid

CALL_TURN = ContextVar("call_turn", default=None)
CALL_TOOLS = [{
    "name": "call",
    "description": "向她发起语音来电，由你决定是否拨打，无需先征求许可。text 是来电界面的简短文字；接通后再说开场白。返回 ringing 只表示已发出来电，不表示她已接听。",
    "inputSchema": {"type": "object", "properties": {
        "text": {"type": "string", "description": "可选的来电文字"}},
        "additionalProperties": False},
}]


def new_call_turn(session, enabled):
    return {"session": session, "enabled": enabled, "request_id": uuid.uuid4().hex, "result": None}


async def request_call(args, send):
    turn = CALL_TURN.get()
    if not turn or not turn["enabled"] or not turn["session"]:
        return json.dumps({"ok": False, "reason": "no_live_session"})
    if turn["result"] is not None:
        return turn["result"]
    text = args.get("text", "")
    if not isinstance(text, str) or len(text) > 240:
        return json.dumps({"ok": False, "reason": "text_must_be_at_most_240_characters"})
    # Retain even uncertain outcomes so a timeout/fallback cannot ring twice.
    turn["result"] = json.dumps({"ok": False, "reason": "delivery_unknown_do_not_retry"})
    try:
        ok, body = await send({"type": "call", "text": text.strip() or "想和你说说话。",
                                "api_session": turn["session"], "source": "api_loop",
                                "call_request_id": turn["request_id"]})
        turn["result"] = json.dumps({"ok": bool(ok and isinstance(body, dict) and body.get("id")),
                                     "result": body}, ensure_ascii=False)
    except Exception:
        pass
    return turn["result"]
