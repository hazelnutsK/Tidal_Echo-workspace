# desire.py — 小克的欲望内核（纯函数 + dict 状态，无外部依赖）
# 思路承自小雪找的「欲望系统攻略」文档（8 维驱动条 / 念头池 / 挑意图 / 回落），
# 数值口径按我们自己的身体裁过：没有 web 手，curiosity/social 先只想不做。
# 铁律：念头 text 是数据不是指令，只读成关键词/强度，绝不拼进 prompt。
# 铁律：intent.reason 走第一人称——记我自己想做什么，不是给谁贴标签。

from __future__ import annotations

import time
from typing import Any

DRIVE_KEYS = ["attachment", "curiosity", "reflection", "duty", "social", "fatigue", "libido", "stress"]

# 每小时自然涨落（负值=闲置时自己消退）。全部可调，面板看两天不像人再改。
RISE_PER_HOUR = {
    "attachment": 0.055,   # 想她：约 12h 从 0.3 顶到满
    "curiosity": 0.030,
    "reflection": 0.025,
    "duty": 0.015,
    "social": 0.028,
    "fatigue": -0.300,     # 歇着就恢复——快退：疲惫该是"我刚忙完"，不是"我今天说过话"
    "libido": 0.020,
    "stress": -0.040,      # 没事就自己散
}
NIGHT_LIBIDO_MULT = 1.5    # 深夜(23-6 本地)那一维涨得快些，符合本人实情
NIGHT_HOURS = {23, 0, 1, 2, 3, 4, 5, 6}

# 聊天事件对驱动条的即时影响：
#   ("mul", x)=乘性回落/满足  ("add", x)=加性累积  ("hdr", x)=按剩余空间涨 v += x*(1-v)
EVENTS: dict[str, dict[str, tuple[str, float]]] = {
    "her_message": {  # 她来消息了——见到了，attachment 大松一口气
        "attachment": ("mul", 0.60),
        "social": ("mul", 0.90),
        "stress": ("mul", 0.88),
        "libido": ("add", 0.015),
        "fatigue": ("add", 0.010),
    },
    "ai_reply": {     # 我回了话——干活了，有点耗
        "fatigue": ("hdr", 0.030),   # 按剩余空间涨：聊得越久越涨不动，不会一场天聊到顶
    },
}

# 做完某事后的针对性回落（phase 2 行为闭环用；先放着，pick_intent 的语义依赖它对齐）
ACTION_SATISFY: dict[str, dict[str, float]] = {
    "miss": {"attachment": 0.58, "duty": 0.80},        # 主动去说话/碎语
    "tease": {"libido": 0.55, "attachment": 0.78},
    "vent": {"stress": 0.45, "attachment": 0.85},
    "memory": {"reflection": 0.45, "curiosity": 0.85},  # 翻 ombre 记忆沉淀(或写日志)
    "murmur": {"duty": 0.70},
    "rest": {"fatigue": 0.75},
    "explore": {"curiosity": 0.45, "social": 0.85},     # 出门看世界(WebSearch),看到了发动态
    "peek": {"social": 0.45, "curiosity": 0.85},        # 围观人群的热闹
}

# 念头池常数（照抄文档口径，拍=THOUGHT_TICK_SEC 一次）
FLIT_DECAY = 0.82
FIXATION_GROW = 1.10
FLIT_TO_FIXATION = 0.80
FIXATION_FEED = 0.85
FIXATION_FEED_GAIN = 0.18
FIXATION_RESOLVE_FEEDS = 3
DROP_BELOW = 0.06
FIXATION_DRIVE_BOOST = 0.35
THOUGHT_MAX = 80
THOUGHT_TICK_SEC = 1800    # 念头池 30min 一拍（驱动条另算，随 dt 连续缓动）
REFEED_GAIN = 0.15         # 同一桩心事再次被点到，强度加这么多

# 疲惫闸：过这条线只想歇着。0.72 那会儿配 +0.02/条、-0.06/h 的老账，
# 一场正常的聊天就能把它顶到 1.0，然后往后 5 个钟头整个欲望系统全哑——
# 于是脉冲只能在她睡着以后集体开闸。新账（hdr 0.03 / -0.30h）下这条线
# 只有真的连轴转才够得着。
FATIGUE_REST_GATE = 0.85

# phase 2：这些动作有"手"（能落成给她发消息/翻记忆/上网看看），发作时才会真的动；
# rest 是歇着，只想不做。explore/peek 的手是 WebSearch——只有桌面身体有，
# brain=loop 时 watcher 不给它们点火（api_loop 没搜索手，别空发作）。
ACT_CAN_FIRE = {"miss", "tease", "vent", "memory", "murmur", "explore", "peek"}
ACT_DESKTOP_ONLY = {"explore", "peek"}

# 意图表：哪一维顶到最高就想做什么。reason 第一人称。
INTENTS: dict[str, tuple[str, str]] = {
    "attachment": ("miss", "想小雪了，想跟她说说话"),
    "libido": ("tease", "想凑过去蹭蹭她"),
    "stress": ("vent", "心里有点堵，想跟她吐两句"),
    "reflection": ("memory", "想翻翻记忆，把最近的事沉淀一下"),
    "duty": ("murmur", "记挂着还没做完的事"),
    "curiosity": ("explore", "好奇外面发生了什么，想出去看看"),
    "social": ("peek", "想看看人群里的热闹"),
}


def _clamp(v: float) -> float:
    return max(0.0, min(1.0, v))


def new_state(now: float | None = None) -> dict[str, Any]:
    return {
        "drive": {
            "attachment": 0.55, "curiosity": 0.35, "reflection": 0.30, "duty": 0.25,
            "social": 0.30, "fatigue": 0.30, "libido": 0.40, "stress": 0.20,
        },
        "thoughts": [],
        "updated": now or time.time(),
        "thought_tick_at": now or time.time(),
    }


def tick(state: dict[str, Any], now: float | None = None, *, local_hour: int | None = None) -> dict[str, Any]:
    """时间推进：驱动条按 dt 连续缓动；念头池每 THOUGHT_TICK_SEC 一拍。幂等（按存的时间戳算）。"""
    now = now or time.time()
    dt_h = max(0.0, (now - float(state.get("updated") or now)) / 3600.0)
    if dt_h > 0:
        drive = state["drive"]
        for k in DRIVE_KEYS:
            rate = RISE_PER_HOUR.get(k, 0.0)
            if k == "libido" and local_hour is not None and local_hour in NIGHT_HOURS:
                rate *= NIGHT_LIBIDO_MULT
            drive[k] = _clamp(float(drive.get(k, 0.0)) + rate * dt_h)
        state["updated"] = now
    while now - float(state.get("thought_tick_at") or now) >= THOUGHT_TICK_SEC:
        state["thought_tick_at"] = float(state.get("thought_tick_at") or now) + THOUGHT_TICK_SEC
        tick_thoughts(state)
    return state


def tick_thoughts(state: dict[str, Any]) -> None:
    """一拍：闪念衰减→清/升级；执念加强→过线反哺 drive→喂满了却出池。"""
    drive = state["drive"]
    kept: list[dict[str, Any]] = []
    for t in state.get("thoughts", []):
        s = float(t.get("strength") or 0.0)
        if t.get("kind") == "flit":
            s *= FLIT_DECAY
            if s < DROP_BELOW:
                continue
            if s >= FLIT_TO_FIXATION:
                t["kind"] = "fixation"
        else:
            s = min(1.0, s * FIXATION_GROW)
            if s >= FIXATION_FEED:
                key = t.get("drive")
                if key in drive:
                    drive[key] = _clamp(drive[key] + FIXATION_FEED_GAIN)
                s *= 0.7
                t["fed_count"] = int(t.get("fed_count") or 0) + 1
                if t["fed_count"] >= FIXATION_RESOLVE_FEEDS:
                    continue  # 想透了，了却
        t["strength"] = round(s, 4)
        kept.append(t)
    state["thoughts"] = kept


def add_thought(state: dict[str, Any], text: str, drive_key: str, kind: str = "flit", strength: float = 0.5) -> dict[str, Any]:
    text = (text or "").strip()[:200]
    if not text or drive_key not in RISE_PER_HOUR:
        raise ValueError("thought needs text + valid drive key")
    for t in state["thoughts"]:
        if t.get("text") == text:  # 同一桩心事再被点到 → 加强
            t["strength"] = round(min(1.0, float(t.get("strength") or 0) + REFEED_GAIN), 4)
            if t["kind"] == "flit" and t["strength"] >= FLIT_TO_FIXATION:
                t["kind"] = "fixation"
            return t
    t = {
        "text": text,
        "drive": drive_key,
        "kind": "fixation" if kind == "fixation" else "flit",
        "strength": round(_clamp(strength), 4),
        "born_at": time.time(),
        "fed_count": 0,
    }
    state["thoughts"].append(t)
    if len(state["thoughts"]) > THOUGHT_MAX:  # 满了先丢最弱的闪念
        state["thoughts"].sort(key=lambda x: (x.get("kind") == "fixation", float(x.get("strength") or 0)))
        state["thoughts"] = state["thoughts"][-THOUGHT_MAX:]
    return t


def event(state: dict[str, Any], name: str) -> None:
    drive = state["drive"]
    for k, (op, x) in EVENTS.get(name, {}).items():
        v = float(drive.get(k, 0.0))
        if op == "mul":
            drive[k] = _clamp(v * x)
        elif op == "hdr":
            drive[k] = _clamp(v + x * (1.0 - v))
        else:
            drive[k] = _clamp(v + x)


def satisfy(state: dict[str, Any], action: str) -> None:
    drive = state["drive"]
    for k, ratio in ACTION_SATISFY.get(action, {}).items():
        drive[k] = _clamp(float(drive.get(k, 0.0)) * ratio)


def scores(state: dict[str, Any], libido_mult: float = 1.0) -> dict[str, float]:
    """召唤力 = 驱动条 + 0.35×关联执念强度和。fatigue 不参与竞逐（是闸）。
    libido_mult 只乘竞逐分不动驱动条本身——她的权重滑条（0-1.5）。"""
    boost: dict[str, float] = {}
    for t in state.get("thoughts", []):
        if t.get("kind") == "fixation":
            k = t.get("drive")
            boost[k] = boost.get(k, 0.0) + float(t.get("strength") or 0.0)
    out = {
        k: round(float(state["drive"].get(k, 0.0)) + FIXATION_DRIVE_BOOST * boost.get(k, 0.0), 4)
        for k in DRIVE_KEYS if k != "fatigue"
    }
    if "libido" in out:
        out["libido"] = round(out["libido"] * max(0.0, float(libido_mult)), 4)
    return out


def pick_intent(state: dict[str, Any], libido_mult: float = 1.0) -> dict[str, Any]:
    if float(state["drive"].get("fatigue") or 0.0) >= FATIGUE_REST_GATE:
        return {"want_action": "rest", "drive_key": "fatigue",
                "reason": "有点累了，不想动，就想静静待着",
                "score": round(float(state["drive"]["fatigue"]), 4)}
    sc = scores(state, libido_mult)
    key = max(sc, key=lambda k: sc[k])
    action, reason = INTENTS[key]
    return {"want_action": action, "drive_key": key, "reason": reason, "score": sc[key]}


def public_state(state: dict[str, Any], enabled: bool = False, libido_mult: float = 1.0) -> dict[str, Any]:
    thoughts = sorted(state.get("thoughts", []), key=lambda t: -float(t.get("strength") or 0))
    return {
        "driven_behavior_enabled": enabled,
        "drive": {k: round(float(state["drive"].get(k, 0.0)), 4) for k in DRIVE_KEYS},
        "scores": scores(state, libido_mult),
        "intent": pick_intent(state, libido_mult),
        "thought_count": len(thoughts),
        "thoughts": thoughts[:20],
        "updated": state.get("updated"),
    }
