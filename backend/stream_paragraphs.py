"""Paragraph boundaries for live replies, independent of token chunk boundaries."""
import re


def stream_paragraphs(text: str) -> tuple[list[str], str]:
    """Return completed paragraphs and the still-growing tail.

    Blank lines inside fenced code are content. Once a structured reply marker
    starts, keep that remainder together for the relay's final card/voice parser.
    Re-scan the accumulated text so CRLF and fences may span arbitrary chunks.
    """
    text = text.replace("\r\n", "\n")
    parts = []
    start = 0
    offset = 0
    fence = ""
    protected = False
    for line in text.splitlines(keepends=True):
        if "[[" in line:
            protected = True
        match = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if match:
            mark = match.group(1)
            if not fence:
                fence = mark
            elif mark[0] == fence[0] and len(mark) >= len(fence) and not line[match.end():].strip():
                fence = ""
        # Only a complete blank line is a boundary, not a trailing single LF.
        if line.endswith("\n") and not line.strip() and not fence and not protected:
            part = text[start:offset].strip()
            if part:
                parts.append(part)
            start = offset + len(line)
        offset += len(line)
    return parts, text[start:]


# 短聊"按句"拆(2026-10-25):句末标点后断开,紧跟的？！和右引号/右括号跟着前一句走。
# 省略号不算句末(“等一下...然后”是一句),小数点、缩写里的点也不算——英文句点后面得跟空白。
_SENTENCE_ENDS = "。！？!?"
_SENTENCE_CLOSERS = "」』”’）)】》"


def _keeps_whole(text: str) -> bool:
    # 代码块和 [[卡片/语音]] 标记整块留着,交给原来的解析
    return "```" in text or "~~~" in text or "[[" in text


def _sentence_spans(text: str) -> list[tuple[int, int]]:
    spans = []
    start = 0
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "\n":
            if text[start:i].strip():
                spans.append((start, i))
            start = i + 1
            i += 1
            continue
        i += 1
        is_end = ch in _SENTENCE_ENDS or (
            ch == "." and (i >= n or text[i].isspace()) and not (i >= 2 and text[i - 2] == ".")
        )
        if not is_end:
            continue
        while i < n and text[i] in _SENTENCE_ENDS:
            i += 1
        while i < n and text[i] in _SENTENCE_CLOSERS:
            i += 1
        if text[start:i].strip():
            spans.append((start, i))
        start = i
    if text[start:].strip():
        spans.append((start, n))
    return spans


def split_sentences(text: str) -> list[str]:
    """One finished paragraph → its sentences (or itself, if it must stay whole)."""
    text = text.strip()
    if not text:
        return []
    if _keeps_whole(text):
        return [text]
    return [text[a:b].strip() for a, b in _sentence_spans(text)] or [text]


def stream_parts(text: str, by_sentence: bool = False) -> tuple[list[str], str]:
    """stream_paragraphs, optionally cut down to sentences.

    The growing tail's last sentence always stays the tail, even when it already
    ends in 。, because a ！ or 」 may still be on its way.
    """
    parts, tail = stream_paragraphs(text)
    if not by_sentence:
        return parts, tail
    parts = [s for p in parts for s in split_sentences(p)]
    if _keeps_whole(tail):
        return parts, tail
    spans = _sentence_spans(tail)
    if len(spans) <= 1:
        return parts, tail
    parts += [tail[a:b].strip() for a, b in spans[:-1]]
    return parts, tail[spans[-1][0]:]


def final_parts(text: str, by_sentence: bool = False) -> list[str]:
    """Every bubble of a finished reply, tail included."""
    parts, tail = stream_parts(text, by_sentence)
    if by_sentence:
        return parts + split_sentences(tail)
    return parts + ([tail.strip()] if tail.strip() else [])
