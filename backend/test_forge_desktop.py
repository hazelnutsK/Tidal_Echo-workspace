"""Offline Forge regression tests; all conversations are synthetic."""
import json
from pathlib import Path
import tempfile
import unittest

import forge_desktop as forge


def human(text, who="human"):
    return {"type": "user", "message": {"role": "user", "content":
        f'<channel source="companion" user="{who}">{text}</channel>'}}


def assistant(*blocks, **extra):
    return {"type": "assistant", "message": {
        "id": "msg-test", "model": "test-model", "role": "assistant",
        "content": list(blocks), "usage": {"input_tokens": 100000}}, **extra}


def reply(text, ident="reply-1", **args):
    return {"type": "tool_use", "name": "mcp__companion__reply",
            "id": ident, "input": {"text": text, **args}}


def result(ident, content="sent", **extra):
    return {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": ident, "content": content, **extra}]}}


class ForgeDialogueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "source.jsonl"

    def prepare(self, events, rounds=2, **kwargs):
        self.path.write_text("".join(json.dumps(e) + "\n" for e in events), encoding="utf-8")
        before = self.path.read_bytes()
        sid, rebuilt, stats = forge.prepare(str(self.path), rounds, **kwargs)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(forge.validate(rebuilt, sid, rounds), (True, "ok"))
        return sid, rebuilt, stats

    def test_default_keeps_exact_dialogue_without_reasoning_or_tools(self):
        _, rows, stats = self.prepare([
            human("A message"),
            assistant({"type": "thinking", "thinking": "PRIVATE", "signature": "SIGNED"}),
            assistant({"type": "redacted_thinking", "data": "ENCRYPTED"}),
            assistant({"type": "tool_use", "name": "Read", "id": "read", "input": {"file_path": "private"}}),
            result("read", "PRIVATE TOOL OUTPUT"),
            assistant({"type": "text", "text": "TERMINAL ONLY"}, reply("Exact reply.\nSecond line.")),
            result("reply-1"),
        ])
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1]["message"]["content"], [{"type": "text", "text": "Exact reply.\nSecond line."}])
        self.assertEqual(stats["thinking_kept"], 0)
        self.assertEqual(stats["thinking_dropped"], 2)
        packed = json.dumps(rows)
        for text in ("PRIVATE", "SIGNED", "ENCRYPTED", "TERMINAL ONLY", "tool_use", "tool_result", "usage"):
            self.assertNotIn(text, packed)

    def test_round_limit_hidden_frames_and_prep(self):
        _, rows, stats = self.prepare([
            human("old"), assistant(reply("old reply")), human("recent"),
            assistant(reply("recent reply")), human("keepalive", "system"),
            assistant(reply("visible proactive reply", "proactive")),
            human("<forge-prep>prepare</forge-prep>", "system"),
            assistant(reply("prep reply must not carry")),
        ], rounds=1, summary_text="Earlier facts")
        packed = json.dumps(rows)
        self.assertEqual(stats["rounds_kept"], 1)
        self.assertIn("Earlier facts", packed)
        self.assertIn("recent reply", packed)
        self.assertIn("visible proactive reply", packed)
        for text in ("old reply", "keepalive", "prep reply", "forge-prep"):
            self.assertNotIn(text, packed)

    def test_second_forge_retains_projected_replies(self):
        _, first, _ = self.prepare([human("Hello"), assistant(reply("Hi"))])
        _, second, stats = self.prepare(first)
        self.assertEqual(second[1]["message"]["content"], [{"type": "text", "text": "Hi"}])
        self.assertEqual(stats["rounds_kept"], 1)

    def test_images_and_multiple_reply_bubbles(self):
        _, rows, stats = self.prepare([human("Photo?"), assistant(
            reply("Here", images=["/tmp/photo.png"]), reply("One more", "reply-2"))])
        self.assertEqual([b["text"] for b in rows[1]["message"]["content"]],
                         ["Here", "[图片: /tmp/photo.png]", "One more"])
        self.assertEqual(stats["images"], 1)

    def test_failed_sends_and_unrelated_reply_tools_not_dialogue(self):
        _, rows, _ = self.prepare([
            human("Hello"), assistant(reply("failed", "bad")), result("bad", is_error=True),
            assistant(reply("mcp failed", "bad-mcp")),
            result("bad-mcp", json.dumps({"isError": True, "content": []})),
            assistant({"type": "tool_use", "name": "mcp__other__reply", "id": "other", "input": {"text": "other channel"}}),
        ])
        self.assertEqual(len(rows), 1)

    def test_pbody_direct_reply_and_silent_turn(self):
        _, rows, _ = self.prepare([human("Hello"),
            assistant({"type": "thinking", "thinking": "PRIVATE"}, {"type": "text", "text": "Hi"}),
            assistant({"type": "text", "text": "[[silent]]"})], reply_mode="pbody")
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1]["message"]["content"], [{"type": "text", "text": "Hi"}])

    def test_legacy_argument_cannot_reenable_reasoning(self):
        _, rows, stats = self.prepare([human("Hi"), assistant(
            {"type": "thinking", "thinking": "PRIVATE", "signature": "SIGNED"}, reply("Hello"))],
            strip_thinking=False)
        self.assertEqual(stats["thinking_kept"], 0)
        self.assertNotIn("PRIVATE", json.dumps(rows))

    def test_forge_writes_valid_file_and_keeps_source(self):
        self.prepare([human("Hello"), assistant(reply("Hi"))])
        source = self.path.read_bytes()
        sid, stats = forge.forge(str(self.path), 1)
        rows = forge.load_events(self.path.parent / (sid + ".jsonl"))
        self.assertEqual(forge.validate(rows, sid, 1), (True, "ok"))
        self.assertEqual(self.path.read_bytes(), source)
        self.assertEqual(stats["thinking_kept"], 0)

    def test_validator_rejects_reasoning(self):
        sid, rows, _ = self.prepare([human("Hi"), assistant(reply("Hello"))])
        rows[1]["message"]["content"].append({"type": "thinking", "thinking": "PRIVATE"})
        self.assertEqual(forge.validate(rows, sid, 2), (False, "non-dialogue content block"))


if __name__ == "__main__":
    unittest.main()
