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
