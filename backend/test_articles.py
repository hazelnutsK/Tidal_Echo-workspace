"""Offline tests for articles: which messages one save gathers, default titles."""
import ast
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest


class ArticleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.conn = sqlite3.connect(Path(self.temp.name) / "relay.db")
        self.conn.row_factory = sqlite3.Row
        self.addCleanup(self.conn.close)
        self.conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, direction TEXT, kind TEXT, text TEXT, meta TEXT)")

        source = Path(__file__).with_name("app.py")
        tree = ast.parse(source.read_text(encoding="utf-8"))
        names = {"rows_to_messages", "article_default_title", "article_source_messages"}
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
        self.assertEqual({n.name for n in nodes}, names)
        self.ns = {"json": json, "ARTICLE_TITLE_MAX": 30}
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), self.ns)

    def insert(self, text, meta=None, kind="reply"):
        cur = self.conn.execute(
            "INSERT INTO messages (ts, direction, kind, text, meta) VALUES ('t', 'out', ?, ?, ?)",
            (kind, text, json.dumps(meta or {}, ensure_ascii=False)),
        )
        return cur.lastrowid

    def gather(self, ids):
        return [m["id"] for m in self.ns["article_source_messages"](self.conn, ids)]

    def test_one_short_chat_bubble_brings_its_whole_reply(self):
        first = self.insert("第一段", {"stream_parent": "s1"})
        self.insert("想法", {"stream_parent": "s1"}, kind="thinking")
        second = self.insert("第二段", {"stream_parent": "s1"})
        self.insert("别的回复", {"stream_parent": "s2"})
        self.assertEqual(self.gather([second]), [first, second])

    def test_selected_messages_stay_as_chosen_and_blank_ones_drop(self):
        a = self.insert("甲", {"stream_parent": "s1"})
        self.insert("乙", {"stream_parent": "s1"})
        blank = self.insert("  ")
        c = self.insert("丙")
        self.assertEqual(self.gather([c, a, blank]), [a, c])
        self.assertEqual(self.gather([blank]), [])

    def test_default_title(self):
        title = self.ns["article_default_title"]
        self.assertEqual(title("\n## **秋天的信**\n正文"), "秋天的信")
        self.assertEqual(title("字" * 40), "字" * 30 + "…")
        self.assertEqual(title("   "), "无题")


if __name__ == "__main__":
    unittest.main()
