#!/usr/bin/env python3
"""epub / txt → relay.db 的书库(books + book_chunks + reading_state)。

只做一件事:把一本书拆成「章」的纯文本入库。插图丢弃,封面单独存一张。
章的边界就是 AI 侧防剧透 clamp 的坐标系,所以顺序必须是 spine 顺序(阅读顺序),
不是文件名顺序、也不是 toc 顺序。
"""

import json
import re
import secrets
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

MIN_CHAPTER_CHARS = 200      # 比这还短的 spine 项(版权页/扉页)并进下一章
TXT_FALLBACK_CHARS = 8000    # txt 切不出章时的等分粒度
TITLE_MAX = 40

_CH_RE = re.compile(r"^\s*第[一二三四五六七八九十百千零两0-9]+[章回节卷篇][^\n]{0,30}$")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _squeeze(text: str) -> str:
    """连续空行压成一个,行尾空白削掉。"""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [ln.strip() for ln in text.split("\n")]
    out, blank = [], False
    for ln in lines:
        if ln:
            out.append(ln)
            blank = False
        elif not blank:
            out.append("")
            blank = True
    return "\n".join(out).strip()


def _first_line_title(text: str) -> str:
    for ln in text.split("\n"):
        ln = ln.strip()
        if ln:
            return ln[:TITLE_MAX]
    return ""


# ---------------------------------------------------------------------------
# epub
# ---------------------------------------------------------------------------

def _toc_titles(book) -> dict:
    """href(去锚点) → toc 标题。epub 的 toc 是嵌套的,拍平。"""
    out = {}

    def walk(items):
        for it in items:
            if isinstance(it, (list, tuple)):
                walk(it)
                continue
            href = getattr(it, "href", "")
            title = (getattr(it, "title", "") or "").strip()
            if href and title:
                out.setdefault(href.split("#", 1)[0], title)

    try:
        walk(book.toc)
    except Exception:
        pass
    return out


def _cover_bytes(book):
    """(bytes, filename) 或 (None, '')。先看 cover meta,再退回文件名含 cover 的图。"""
    import ebooklib

    cover_id = ""
    try:
        metas = book.get_metadata("OPF", "cover")
        if metas:
            cover_id = metas[0][1].get("content", "")
    except Exception:
        pass
    items = list(book.get_items_of_type(ebooklib.ITEM_IMAGE)) + list(
        book.get_items_of_type(ebooklib.ITEM_COVER)
    )
    if cover_id:
        for it in items:
            if it.get_id() == cover_id:
                return it.get_content(), it.get_name()
    for it in items:
        if "cover" in (it.get_name() or "").lower():
            return it.get_content(), it.get_name()
    return None, ""


def parse_epub(path: Path) -> dict:
    """→ {title, author, cover:(bytes,name), chapters:[{title,text}]}"""
    import ebooklib
    from ebooklib import epub
    from bs4 import BeautifulSoup

    book = epub.read_epub(str(path))
    title = ""
    author = ""
    try:
        t = book.get_metadata("DC", "title")
        if t:
            title = (t[0][0] or "").strip()
        a = book.get_metadata("DC", "creator")
        if a:
            author = (a[0][0] or "").strip()
    except Exception:
        pass
    if not title:
        title = path.stem

    toc = _toc_titles(book)
    id_map = {it.get_id(): it for it in book.get_items()}

    raw = []   # [(href, title_hint, text)]
    for spine_id, _linear in book.spine:
        item = id_map.get(spine_id)
        if item is None or item.get_type() != ebooklib.ITEM_DOCUMENT:
            continue
        try:
            soup = BeautifulSoup(item.get_content(), "html.parser")
        except Exception:
            continue
        for tag in soup(["script", "style"]):
            tag.decompose()
        text = _squeeze(soup.get_text("\n"))
        if not text:
            continue
        href = (item.get_name() or "").split("#", 1)[0]
        hint = toc.get(href, "")
        if not hint:
            h = soup.find(["h1", "h2", "h3", "title"])
            if h:
                hint = h.get_text(" ", strip=True)[:TITLE_MAX]
        raw.append((href, hint, text))

    chapters = _merge_short(raw)
    cover = _cover_bytes(book)
    return {"title": title, "author": author, "cover": cover, "chapters": chapters}


def _merge_short(raw: list) -> list:
    """过短的项并进下一章(末尾的短项并进上一章),避免几十个碎章。"""
    chapters, carry_text, carry_title = [], "", ""
    for _href, hint, text in raw:
        if carry_text:
            text = carry_text + "\n\n" + text
            hint = carry_title or hint
            carry_text, carry_title = "", ""
        if len(text) < MIN_CHAPTER_CHARS:
            carry_text, carry_title = text, hint
            continue
        chapters.append({"title": (hint or _first_line_title(text))[:TITLE_MAX], "text": text})
    if carry_text:
        if chapters:
            chapters[-1]["text"] += "\n\n" + carry_text
        else:
            chapters.append({"title": (carry_title or _first_line_title(carry_text))[:TITLE_MAX],
                             "text": carry_text})
    return chapters


# ---------------------------------------------------------------------------
# txt 兜底
# ---------------------------------------------------------------------------

def parse_txt(path: Path) -> dict:
    data = path.read_bytes()
    text = ""
    for enc in ("utf-8", "utf-8-sig", "gb18030", "big5"):
        try:
            text = data.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    if not text:
        text = data.decode("utf-8", errors="replace")
    text = _squeeze(text)

    lines = text.split("\n")
    marks = [i for i, ln in enumerate(lines) if _CH_RE.match(ln)]
    chapters = []
    if len(marks) >= 2:
        if marks[0] > 0:
            head = "\n".join(lines[:marks[0]]).strip()
            if len(head) >= MIN_CHAPTER_CHARS:
                chapters.append({"title": "开头", "text": head})
        for n, start in enumerate(marks):
            end = marks[n + 1] if n + 1 < len(marks) else len(lines)
            body = "\n".join(lines[start:end]).strip()
            if body:
                chapters.append({"title": lines[start].strip()[:TITLE_MAX], "text": body})
        chapters = _merge_short([("", c["title"], c["text"]) for c in chapters])
    else:
        for i in range(0, len(text), TXT_FALLBACK_CHARS):
            seg = text[i:i + TXT_FALLBACK_CHARS].strip()
            if seg:
                chapters.append({"title": f"第 {len(chapters) + 1} 节", "text": seg})
    return {"title": path.stem, "author": "", "cover": (None, ""), "chapters": chapters}


# ---------------------------------------------------------------------------
# 入库
# ---------------------------------------------------------------------------

def import_book(path, db_path: str, upload_dir, title_hint: str = "") -> dict:
    """把一本书写进库,返回 {book_id, title, author, chapters, chars}。"""
    path = Path(path)
    upload_dir = Path(upload_dir)
    if path.suffix.lower() == ".epub":
        parsed = parse_epub(path)
    else:
        parsed = parse_txt(path)

    chapters = parsed["chapters"]
    if not chapters:
        raise ValueError("这本书没解析出正文")

    title = (title_hint or parsed["title"] or path.stem).strip()[:120]
    author = (parsed["author"] or "").strip()[:80]

    cover_name = ""
    data, name = parsed["cover"]
    if data:
        ext = Path(name or "").suffix.lower()
        if not re.fullmatch(r"\.[A-Za-z0-9]{1,8}", ext or ""):
            ext = ".jpg"
        cover_name = f"bookcover-{secrets.token_urlsafe(10)}{ext}"
        upload_dir.mkdir(parents=True, exist_ok=True)
        (upload_dir / cover_name).write_bytes(data)

    total_chars = sum(len(c["text"]) for c in chapters)
    now = _now()
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.execute(
            "INSERT INTO books (title, author, cover, total_chapters, total_chars, created_at, meta) "
            "VALUES (?,?,?,?,?,?,?)",
            (title, author, cover_name, len(chapters), total_chars, now, json.dumps({})),
        )
        book_id = cur.lastrowid
        conn.executemany(
            "INSERT INTO book_chunks (book_id, chapter_idx, chapter_title, text, char_count) "
            "VALUES (?,?,?,?,?)",
            [(book_id, i, c["title"], c["text"], len(c["text"])) for i, c in enumerate(chapters)],
        )
        conn.execute(
            "INSERT OR REPLACE INTO reading_state "
            "(book_id, cur_chapter, cur_offset, furthest_chapter, furthest_offset, updated_at, last_heartbeat) "
            "VALUES (?,0,0,0,0,?,'')",
            (book_id, now),
        )
        conn.commit()
    finally:
        conn.close()
    return {"book_id": book_id, "title": title, "author": author,
            "chapters": len(chapters), "chars": total_chars, "cover": cover_name}


if __name__ == "__main__":
    import sys
    p = Path(sys.argv[1])
    d = parse_epub(p) if p.suffix.lower() == ".epub" else parse_txt(p)
    print(d["title"], "|", d["author"], "|", len(d["chapters"]), "chapters",
          "|", sum(len(c['text']) for c in d['chapters']), "chars",
          "| cover:", bool(d["cover"][0]))
    for i, c in enumerate(d["chapters"][:12]):
        print(f"  [{i}] {c['title'][:30]!r} {len(c['text'])}")
