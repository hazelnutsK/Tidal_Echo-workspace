"""Offline tests for quote replies: snapshot from SQLite, AI-facing lead line."""
import ast
import json
from pathlib import Path
import re
import sqlite3
import tempfile
import unittest


class QuoteReplyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "relay.db"

        def db():
            conn = sqlite3.connect(self.path)
            conn.row_factory = sqlite3.Row
            self.addCleanup(conn.close)
            return conn

        self.db = db
        with db() as conn:
            conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, direction TEXT, kind TEXT, text TEXT, meta TEXT)")

        source = Path(__file__).with_name("app.py")
        tree = ast.parse(source.read_text(encoding="utf-8"))
        names = {"quote_snapshot", "quote_line"}
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
        self.assertEqual({n.name for n in nodes}, names)
        self.ns = {"db": db, "json": json, "re": re, "QUOTE_MAX_CHARS": 200}
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), self.ns)

    def insert(self, direction, text, meta=None):
        with self.db() as conn:
            cur = conn.execute(
                "INSERT INTO messages (ts, direction, kind, text, meta) VALUES ('t', ?, 'reply', ?, ?)",
                (direction, text, json.dumps(meta or {}, ensure_ascii=False)),
            )
            conn.commit()
            return cur.lastrowid

    def test_snapshot_of_ai_message(self):
        mid = self.insert("out", "今晚早点睡\n  别熬了")
        quote = self.ns["quote_snapshot"](str(mid))
        self.assertEqual(quote, {"id": mid, "from": "ai", "text": "今晚早点睡 别熬了"})
        self.assertEqual(
            self.ns["quote_line"]({"quote": quote}),
            "[她引用了你之前说的:「今晚早点睡 别熬了」,下面是她对这句的回复]\n",
        )

    def test_snapshot_of_her_photo_and_long_text(self):
        photo = self.insert("in", "", {"attachments": [{"mime": "image/jpeg", "url": "/a.jpg"}]})
        self.assertEqual(self.ns["quote_snapshot"](photo)["text"], "[图片]")
        self.assertIn("她自己之前说的", self.ns["quote_line"]({"quote": self.ns["quote_snapshot"](photo)}))
        long_id = self.insert("out", "字" * 300)
        self.assertEqual(len(self.ns["quote_snapshot"](long_id)["text"]), 201)

    def test_missing_or_bad_ids(self):
        for value in (None, "", "abc", 0, -3, 999):
            self.assertIsNone(self.ns["quote_snapshot"](value))
        self.assertEqual(self.ns["quote_line"]({}), "")
        self.assertEqual(self.ns["quote_line"]({"quote": "bad"}), "")


if __name__ == "__main__":
    unittest.main()
