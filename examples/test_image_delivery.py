"""Offline image regressions; do not load private config or call a model."""
import base64
import io
import json
import random
import tempfile
import unittest
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps
from test_wechat_cache import ROOT, load_functions


class ImageDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.uploads = Path(self.temp.name)
        self.ns = dict(Any=Any, json=json, io=io, base64=base64,
                       Image=Image, ImageOps=ImageOps, UPLOAD_DIR=self.uploads,
                       IMAGE_MAX_BYTES=5 * 1024 * 1024, IMAGE_MAX_PER_MESSAGE=6)
        load_functions(ROOT / "examples/api_loop.py", {
            "_parse_meta", "_fit_image_for_model", "_image_parts_from_meta",
            "_content_to_anthropic_blocks",
        }, self.ns)

    def deliver(self, data, mime="image/png"):
        (self.uploads / "photo.png").write_bytes(data)
        meta = {"attachments": [{"kind": "image", "mime": mime,
                                  "url": "/relay/uploads/photo.png"}]}
        parts = self.ns["_image_parts_from_meta"](meta)
        self.assertEqual(parts, self.ns["_image_parts_from_meta"](json.dumps(meta)))
        return self.ns["_content_to_anthropic_blocks"](parts)

    def test_large_photo_reaches_model_as_valid_image_and_original_is_unchanged(self):
        image = Image.frombytes("RGB", (1600, 1200), random.Random(17).randbytes(1600 * 1200 * 3))
        output = io.BytesIO()
        image.save(output, format="PNG")
        original = output.getvalue()
        self.assertGreater(len(original), self.ns["IMAGE_MAX_BYTES"])
        blocks = self.deliver(original)
        self.assertEqual(len(blocks), 1)
        self.assertEqual(blocks[0]["type"], "image")
        self.assertEqual(blocks[0]["source"]["media_type"], "image/jpeg")
        data = base64.b64decode(blocks[0]["source"]["data"])
        self.assertLessEqual(len(data), self.ns["IMAGE_MAX_BYTES"])
        with Image.open(io.BytesIO(data)) as result:
            result.load()
            self.assertEqual(result.size, image.size)
        self.assertEqual((self.uploads / "photo.png").read_bytes(), original)

    def test_small_image_keeps_exact_bytes_and_mime(self):
        output = io.BytesIO()
        Image.new("RGBA", (20, 10), (0, 0, 0, 0)).save(output, format="PNG")
        blocks = self.deliver(output.getvalue())
        self.assertEqual(blocks[0]["source"]["media_type"], "image/png")
        self.assertEqual(base64.b64decode(blocks[0]["source"]["data"]), output.getvalue())

    def test_missing_or_corrupt_oversized_image_is_explicit_in_model_input(self):
        blocks = self.deliver(b"invalid" * 800000)
        self.assertEqual(blocks[0]["type"], "text")
        self.assertIn("无法查看", blocks[0]["text"])
        (self.uploads / "photo.png").unlink()
        parts = self.ns["_image_parts_from_meta"]({"attachments": [
            {"kind": "image", "url": "/relay/uploads/photo.png"}]})
        self.assertEqual(parts[0]["type"], "text")

    def test_exif_orientation_is_applied_to_oversized_photo(self):
        output = io.BytesIO()
        exif = Image.Exif()
        exif[274] = 6
        Image.new("RGB", (80, 40), "red").save(output, format="JPEG", exif=exif)
        self.ns["IMAGE_MAX_BYTES"] = 1000
        data, mime = self.ns["_fit_image_for_model"](output.getvalue() + b"\0" * 1100, "image/jpeg")
        with Image.open(io.BytesIO(data)) as result:
            self.assertEqual(result.size, (40, 80))
        self.assertEqual(mime, "image/jpeg")


if __name__ == "__main__":
    unittest.main()
