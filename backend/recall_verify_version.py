#!/usr/bin/env python3
"""判定日志里每条记忆正文能不能代表「当时注入给模型的那一版」。

    python recall_verify_version.py          看判定分布
    python recall_verify_version.py --mark   把判定写进日志 card 的 ver 字段

**问题**:标注要判「这条记忆该不该为这句话浮出来」,看到的必须是模型当时真正
看到的正文。但历史日志的正文是**事后回填**的(当时没存),取回的是「现在这版」。
而 ombre 的 bucket metadata 只有 created / last_active / activation_count,
**没有内容修改时间戳**;last_active 按代码注释只在 hold/grow 合并时 bump,
普通召回的 touch 也会 bump——两者无法区分。所以「那轮之后改没改过」在 ombre
侧查不出来,不是拿不到数据,是这个数据不存在。

**能做到的**:E:\\backups\\ombre-buckets-20260719.tar.gz 是 2026-07-19 的快照,
早于所有日志轮次(8/17~8/31)。于是有一个充分条件:

    备份(7-19) == 现在  ⇒ 这 6 周没变过 ⇒ 8 月那轮浮现时也是这一版  → ok
    不相等                                                        → changed
    备份里没有(7-19 之后才写的)                                     → new
    正文取不到                                                     → unknown

只有 ok 能保证标注看到的就是当时那版。**这是充分不必要条件**:判成 new 的
不代表一定变过,只是无从证明。

根因已修:relay 现在在浮现的当下就存完整正文(recall.py 的 `"text"`),
新数据不需要回填,也就没有这个版本漂移问题——这个脚本只为补救历史那批。
"""
import json
import re
import sqlite3
import sys
from collections import Counter
from pathlib import Path

DB = Path(__file__).parent / "relay.db"
DEFAULT_BACKUP = Path(
    r"C:\Users\sxc\AppData\Local\Temp\claude\C--Users-sxc"
    r"\80584b3e-263a-4e4b-8b0d-024242a309e9\scratchpad\ob0719"
)
_MISSING_PREFIX = "(取不到"

LABEL = {
    "ok": "可确认(7-19 至今未变)",
    "changed": "改过(时点不明)",
    "new": "7-19 之后新建,无从比对",
    "unknown": "正文取不到",
}


def strip_wikilinks(text: str) -> str:
    """跟 ombre src/utils.py 同一条规则 —— 不对齐的话会全判成不一致。"""
    return re.sub(r"\[\[([^\]]+)\]\]", r"\1", text) if text else text


def normalize(text: str) -> str:
    """只比实质内容:去 wikilink、压掉所有空白。行尾/缩进差异不算「改过」。"""
    return re.sub(r"\s+", "", strip_wikilinks(str(text or "")))


def load_backup(folder: Path) -> dict[str, str]:
    """→ {bucket_id: 正文}。frontmatter 之后才是正文。"""
    out: dict[str, str] = {}
    for path in folder.rglob("*.md"):
        raw = path.read_text(encoding="utf-8", errors="replace")
        if not raw.startswith("---"):
            continue
        parts = raw.split("---", 2)
        if len(parts) < 3:
            continue
        m = re.search(r"^id:\s*(\S+)\s*$", parts[1], re.M)
        if m:
            out[m.group(1).strip().strip("'\"")] = parts[2].strip()
    return out


def judge(bucket_id: str, text: str, backup: dict[str, str]) -> str:
    if not text or text.startswith(_MISSING_PREFIX):
        return "unknown"
    if bucket_id not in backup:
        return "new"
    return "ok" if normalize(backup[bucket_id]) == normalize(text) else "changed"


def main() -> None:
    args = sys.argv[1:]
    mark = "--mark" in args
    backup_dir = Path(args[args.index("--backup") + 1]) if "--backup" in args else DEFAULT_BACKUP
    backup = load_backup(backup_dir)
    print(f"备份快照:{len(backup)} 条（{backup_dir.name}）\n")

    db = sqlite3.connect(DB)
    db.row_factory = sqlite3.Row
    rows = list(db.execute("SELECT id, cards FROM recall_log WHERE surfaced > 0"))

    per_card, per_bucket = Counter(), {}
    updates = []
    for row in rows:
        cards = json.loads(row["cards"] or "[]")
        changed = False
        for card in cards:
            bid = str(card.get("id") or "")
            verdict = judge(bid, card.get("text") or "", backup)
            per_card[verdict] += 1
            per_bucket[bid] = verdict
            if mark and card.get("ver") != verdict:
                card["ver"] = verdict
                changed = True
        if changed:
            updates.append((json.dumps(cards, ensure_ascii=False), row["id"]))

    print("=== 按浮现条目 ===")
    for name, count in per_card.most_common():
        print(f"  {LABEL.get(name, name):<24} {count}")
    print("\n=== 按记忆条目 ===")
    for name, count in Counter(per_bucket.values()).most_common():
        print(f"  {LABEL.get(name, name):<24} {count}")

    ok = per_card.get("ok", 0)
    print(f"\n可用于标注的条目 {ok} / {sum(per_card.values())}")
    if per_card.get("changed"):
        print("  ⚠ 有 changed —— 这些记忆的正文确实变过,拿现在这版去标注是错的材料")

    if mark:
        db.executemany("UPDATE recall_log SET cards = ? WHERE id = ?", updates)
        db.commit()
        print(f"\n已写回 {len(updates)} 行日志的 ver 字段")
    else:
        print("\n(只看不写。要写进日志加 --mark)")


if __name__ == "__main__":
    main()
