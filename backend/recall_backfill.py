#!/usr/bin/env python3
"""给历史召回日志补上记忆正文 —— 人工裁决要看正文，光有标题判不了。

    python recall_backfill.py --dry    看要补多少条，不动数据
    python recall_backfill.py          真的补

原理：bucket_manager.search() 有条 bucket-id 直达通道（查询串正好等于某个可见
桶的完整 id 就短路返回那一条）。所以拿 id 当 query 打 /api/recall 就能取回正文，
不需要新端点。

只填 text 为空的条目，不覆盖已有内容；取不到的（桶被删了 / 归档了）明确标注，
不留空白让人以为是漏填。
"""
import json
import re
import sqlite3
import sys
import time
from pathlib import Path

import httpx

DB = Path(__file__).parent / "relay.db"
ENV = Path(__file__).parent / "relay.env"
_MISSING = "(取不到：这条记忆可能已被删除或归档)"


def cfg(key: str) -> str:
    text = ENV.read_text(encoding="utf-8")
    m = re.search(rf"^{key}\s*=\s*(.+)$", text, re.M)
    return m.group(1).strip().strip('"') if m else ""


FORCE = False          # --force：连已有正文一起重取（旧数据存的是 300 字截断版）


def blank(card: dict) -> bool:
    """还需要补正文吗。

    上一版把请求失败也写成了 _MISSING,所以「标着取不到」同样算待补 ——
    否则一次网络抖动就把那条永久钉死成「这条记忆没了」。
    """
    text = (card.get("text") or "").strip()
    return FORCE or not text or text.startswith(_MISSING[:5])


def needs_backfill(cards: list) -> bool:
    return any(blank(c) for c in cards)


def main() -> None:
    global FORCE
    dry = "--dry" in sys.argv
    FORCE = "--force" in sys.argv
    db = sqlite3.connect(DB)
    db.row_factory = sqlite3.Row
    rows = [r for r in db.execute("SELECT id, cards FROM recall_log WHERE surfaced > 0")]

    todo: dict[str, list] = {}          # bucket_id → [(log_id, card_index)]
    for row in rows:
        cards = json.loads(row["cards"] or "[]")
        if not needs_backfill(cards):
            continue
        for idx, card in enumerate(cards):
            if blank(card) and card.get("id"):
                todo.setdefault(str(card["id"]), []).append((row["id"], idx))

    spots = sum(len(v) for v in todo.values())
    print(f"要补 {spots} 处正文，涉及 {len(todo)} 条不同的记忆")
    if dry or not todo:
        if not todo:
            print("没有需要补的。")
        return

    url, token = cfg("RECALL_URL").rstrip("/"), cfg("RECALL_TOKEN")
    if not url or not token:
        print("relay.env 里没有 RECALL_URL / RECALL_TOKEN")
        return

    fetched: dict[str, str] = {}
    errors: dict[str, int] = {}
    with httpx.Client(base_url=url, headers={"Authorization": f"Bearer {token}"}) as client:
        for i, bucket_id in enumerate(todo, 1):
            # 服务端并发槽只有 4 个,relay 同时也在用;撞上就退避重试。
            # **必须看状态码**:429 的 body 里没有 cards,不看的话会被静默
            # 记成「这条记忆取不到」——把故障读成结果,正是这轮在修的那个毛病。
            for attempt in range(4):
                try:
                    # id 直达通道:query 正好等于完整 id → 短路返回那一条
                    resp = client.post("/api/recall", json={
                        "query": bucket_id, "max_results": 1,
                        "max_chars": 20000,      # 要完整正文,别让服务端替我截
                        "trace_id": "backfill",
                    }, timeout=25.0)
                    if resp.status_code == 429:      # busy,让一让再来
                        time.sleep(1.5 * (attempt + 1))
                        continue
                    if resp.status_code != 200:
                        errors[f"HTTP {resp.status_code}"] = errors.get(f"HTTP {resp.status_code}", 0) + 1
                        break
                    cards = (resp.json() or {}).get("cards") or []
                    hit = next((c for c in cards if str(c.get("id")) == bucket_id), None)
                    if hit is None:
                        fetched[bucket_id] = _MISSING     # 真的查不到这条
                    else:
                        fetched[bucket_id] = hit.get("content") or _MISSING
                    break
                except Exception as exc:
                    errors[type(exc).__name__] = errors.get(type(exc).__name__, 0) + 1
                    time.sleep(1.0 * (attempt + 1))
            else:
                errors["429 重试用尽"] = errors.get("429 重试用尽", 0) + 1
            if i % 10 == 0:
                print(f"  [{i}/{len(todo)}] ...", flush=True)
            time.sleep(0.3)          # 别把服务端的并发槽占满

    patched = 0
    for row in rows:
        cards = json.loads(row["cards"] or "[]")
        changed = False
        for card in cards:
            text = fetched.get(str(card.get("id")))
            if text and blank(card):
                card["text"] = text          # **不截断**：标注要看模型当时看到的全文
                changed = True
        if changed:
            db.execute("UPDATE recall_log SET cards = ? WHERE id = ?",
                       (json.dumps(cards, ensure_ascii=False), row["id"]))
            patched += 1
    db.commit()

    got = sum(1 for v in fetched.values() if v != _MISSING)
    absent = sum(1 for v in fetched.values() if v == _MISSING)
    print(f"\n补好了：{got}/{len(todo)} 条记忆取到正文，写回 {patched} 行日志")
    if absent:
        print(f"  {absent} 条服务端确认查不到（记忆已删/归档），已标注原因")
    if errors:
        # 请求失败 ≠ 记忆不存在。混为一谈就会把「服务端忙」记成「这条没了」。
        print(f"  ⚠ {sum(errors.values())} 次请求失败，这些 id 没有结论，重跑即可：")
        for name, count in sorted(errors.items(), key=lambda kv: -kv[1]):
            print(f"      {name}: {count}")


if __name__ == "__main__":
    main()
