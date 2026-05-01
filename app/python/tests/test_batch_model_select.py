from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

from batch_model_select import PROMPT, attach_target_context, target_image_content_item  # noqa: E402


class BatchModelSelectTargetImageTests(unittest.TestCase):
    def test_attach_target_context_uses_raw_target_for_ocr_when_model_target_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target_meta = root / "target_metadata.json"
            geometry = root / "geometry.json"
            target_meta.write_text(json.dumps({"focused_label": "Document content"}), encoding="utf-8")
            geometry.write_text(json.dumps({"status": "ok"}), encoding="utf-8")
            raw_target = root / "target.png"
            model_target = root / "target_annotated.png"

            args = SimpleNamespace(
                target=raw_target,
                model_target=model_target,
                target_meta=target_meta,
                geometry=geometry,
                target_packet_out=None,
                target_build_out=None,
            )
            request_payload: dict[str, object] = {}

            with patch(
                "batch_model_select.build_target_ocr_packet",
                return_value={
                    "target_mode": "document_canvas",
                    "packet_text": "",
                    "completeness": "needs_target_image",
                    "fallback_reasons": [],
                    "packet_chars": 0,
                    "build_log": {},
                },
            ) as build_packet:
                attach_target_context(request_payload, args)

            self.assertEqual(build_packet.call_args.kwargs["target_path"], raw_target)

    def test_target_image_item_uses_annotated_model_target_when_pixels_are_needed(self) -> None:
        request_payload = {"target_context": {"mode": "document_canvas"}}
        args = SimpleNamespace(
            target=Path("/tmp/target.png"),
            model_target=Path("/tmp/target_annotated.png"),
        )

        item = target_image_content_item(
            request_payload,
            {"completeness": "needs_target_image"},
            args,
        )

        self.assertEqual(item["type"], "image")
        self.assertEqual(item["path"], Path("/tmp/target_annotated.png"))
        self.assertEqual(
            request_payload["target_context"]["model_target_image"]["source"],
            "annotated",
        )
        self.assertEqual(
            request_payload["target_context"]["model_target_image"]["artifact"],
            "target_annotated.png",
        )
        self.assertNotIn(
            "path",
            request_payload["target_context"]["model_target_image"],
        )

    def test_target_image_item_skips_sufficient_packets(self) -> None:
        request_payload = {"target_context": {"mode": "strict_field"}}
        args = SimpleNamespace(target=Path("/tmp/target.png"), model_target=None)

        item = target_image_content_item(request_payload, {"completeness": "sufficient"}, args)

        self.assertIsNone(item)
        self.assertNotIn("model_target_image", request_payload["target_context"])

    def test_prompt_allows_rich_image_fragment_selection(self) -> None:
        self.assertIn("rich image-fragment handle", PROMPT)
        self.assertIn("whole slide/layout selection", PROMPT)


if __name__ == "__main__":
    unittest.main()
