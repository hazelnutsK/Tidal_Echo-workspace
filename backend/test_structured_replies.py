"""Exercise real reply/marker handlers with temporary SQLite and fake TTS."""
import ast
import asyncio
from datetime import timedelta
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock

from stream_paragraphs import split_sentences
import test_stream_paragraphs as paragraph_tests


class StructuredReplyTests(unittest.IsolatedAsyncioTestCase):
    rows = paragraph_tests.ParagraphRelayTests.rows
    send = paragraph_tests.ParagraphRelayTests.send

    def setUp(self):
        paragraph_tests.ParagraphRelayTests.setUp(self)
        self.settings.update(short_split="sentence", short_strip_terminal_periods=True)
        with self.db() as conn:
            conn.execute("CREATE TABLE album (id INTEGER PRIMARY KEY, url TEXT UNIQUE, "
                         "kept_at TEXT, photo_ts TEXT, title TEXT, note TEXT, src_id INTEGER, msg_id INTEGER)")
        self.tts = Mock(return_value=b"fake audio")
        self.ns.update({
            "asyncio": SimpleNamespace(to_thread=asyncio.to_thread, sleep=AsyncMock(),
                                       create_task=Mock(side_effect=lambda coro: coro.close())),
            "sys": sys, "timedelta": timedelta, "Request": object,
            "check_auth": Mock(), "inherit_book_ref": lambda: None,
            "split_sentences": split_sentences, "_broadcast_reply_parts": AsyncMock(),
            "tts_configured": Mock(return_value=True), "tts_mp3": self.tts,
            "binaural": SimpleNamespace(strip_tags=lambda s: s, has_tags=lambda s: False,
                                        BINAURAL_ALWAYS=False),
            "save_upload_bytes": Mock(return_value={"kind": "audio", "url": "/fake.mp3"}),
        })
        functions = {
            "apply_voice_note", "strip_audio_tags", "strip_sysnote_leak",
            "strip_timer_marker", "strip_ask_marker", "strip_peek_marker", "strip_album_marker",
            "_images_in_meta", "latest_photo_message", "commit_album", "channel_out", "split_reply_parts",
        }
        constants = {"VOICE_MARKER_RE", "AUDIO_TAG_RE", "SYSNOTE_LEAK_RE", "TIMER_MARKER_RE",
                     "ASK_MARKER_RE", "PEEK_MARKER_RE", "PEEK_PENDING_TTL",
                     "ALBUM_MARKER_RE", "ALBUM_MARKER_STRIP_RE"}
        source = Path(__file__).with_name("app.py")
        nodes = []
        for node in ast.parse(source.read_text(encoding="utf-8")).body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in functions:
                node.decorator_list = []
                nodes.append(node)
            elif isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in constants
                                                       for t in node.targets):
                nodes.append(node)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), self.ns)

    async def deliver(self, text, streaming, sid="structured"):
        if streaming:
            for char in text:
                await self.send(char, sid=sid)
            return await self.send(done=True, final=text, sid=sid)
        return await self.ns["channel_out"](SimpleNamespace(json=AsyncMock(return_value={
            "type": "reply", "text": text, "api_session": "test-window",
        })))

    async def test_failed_voice_does_not_turn_into_sentence_burst(self):
        self.tts.side_effect = OSError("synthetic connection interrupted")
        await self.deliver("[[voice]]第一句。第二句。\n\n第三句。", False)
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["text"], "第一句。第二句。\n\n第三句。")
        self.assertTrue(rows[0]["meta"]["voice_requested"])
        self.assertIn("voice_failed", rows[0]["meta"])
        self.assertEqual(self.tts.call_count, 2)  # Existing retry still runs.

    async def test_unconfigured_voice_is_still_one_reply(self):
        self.settings["short_split"] = "paragraph"
        self.ns["tts_configured"].return_value = False
        await self.deliver("[[voice:en]]First.\n\nSecond.", False)
        self.assertEqual(len(self.rows()), 1)
        self.assertTrue(self.rows()[0]["meta"]["voice_requested"])
        self.tts.assert_not_called()

    async def test_successful_voice_keeps_audio_and_language_in_both_paths(self):
        for streaming in (False, True):
            with self.subTest(streaming=streaming):
                before = len(self.rows())
                self.tts.reset_mock()
                await self.deliver("[[voice:en]][whispers]Hello. Still here!", streaming)
                rows = self.rows()[before:]
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]["text"], "Hello. Still here!")
                self.assertTrue(rows[0]["meta"]["attachments"][0]["voice"])
                self.tts.assert_called_once_with("[whispers]Hello. Still here!", "en")

    async def test_late_failed_voice_reconciles_sentences_into_one(self):
        self.tts.side_effect = OSError("synthetic connection interrupted")
        await self.send("第一句。第二句。第三句。")
        first_id = self.rows()[0]["id"]
        self.assertEqual(len(self.rows()), 2)
        await self.send("[[voice]]")
        await self.send(done=True, final="第一句。第二句。第三句。[[voice]]")
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.rows()[0]["id"], first_id)
        self.assertIn("voice_failed", self.rows()[0]["meta"])

    async def test_cards_and_photo_collection_survive_both_delivery_paths(self):
        photo = self.ns["save_message"]("in", "user", "", {
            "attachments": [{"kind": "image", "url": "/fixture.jpg"}],
        })
        markers = {"timer": "[[timer:5:喝水]]", "ask": "[[ask:选哪个？|茶|水]]",
                   "peek": "[[peek:看一眼]]", "album": "[[keep:风景|留着。以后看。]]"}
        for streaming in (False, True):
            for key, marker in markers.items():
                for prose in ("", "第一句。第二句。\n\n"):
                    with self.subTest(streaming=streaming, card=key, prose=bool(prose)):
                        before = len(self.rows())
                        result = await self.deliver(prose + marker, streaming)
                        rows = self.rows()[before:]
                        self.assertEqual(len(rows), 1)
                        self.assertEqual(result["id"], rows[0]["id"])
                        self.assertNotIn("[[", rows[0]["text"])
                        self.assertTrue(rows[0]["meta"][key])
                        if key == "timer":
                            self.ns["arm_timer"].assert_called_with(unittest.mock.ANY)
                            self.assertEqual(self.ns["arm_timer"].call_args.args[0]["meta"][key]["minutes"], 5)
                        elif key == "peek":
                            self.assertEqual(self.ns["arm_peek"].call_args.args[0]["meta"][key]["status"], "pending")
                        elif key == "album":
                            with self.db() as conn:
                                entry = conn.execute("SELECT * FROM album").fetchone()
                            self.assertEqual(entry["src_id"], photo["id"])
                            self.assertEqual(entry["msg_id"], rows[0]["id"])
                            self.assertEqual(entry["note"], "留着。以后看。")

    async def test_plain_text_and_images_still_split(self):
        self.assertEqual(self.ns["split_reply_parts"]("第一句。第二句。", {}), ["第一句", "第二句"])
        self.assertEqual(self.ns["split_reply_parts"]("第一句。第二句。", {
            "attachments": [{"kind": "image", "url": "/fixture.jpg"}],
        }), ["第一句", "第二句"])


if __name__ == "__main__":
    unittest.main()
