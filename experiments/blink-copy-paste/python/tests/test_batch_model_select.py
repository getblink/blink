from __future__ import annotations

import contextlib
import io
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

from batch_model_select import PROMPT, attach_target_context, main, target_image_content_item  # noqa: E402
from model_runner import _prepare_content_items  # noqa: E402


class BatchModelSelectTargetImageTests(unittest.TestCase):
    def test_document_canvas_with_model_target_skips_ocr_fast_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target_meta = root / "target_metadata.json"
            geometry = root / "geometry.json"
            raw_target = root / "target.png"
            model_target = root / "target_annotated.request.jpg"
            target_meta.write_text(
                json.dumps(
                    {
                        "target_mode": "document_canvas",
                        "target_copy_probe": {
                            "status": "ok",
                            "plain_text_bytes": 11,
                            "string_preview": "Title slide",
                        },
                    }
                ),
                encoding="utf-8",
            )
            geometry.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "annotation_metadata": {
                            "annotated_target": "target_annotated.request.jpg",
                            "format": "jpeg",
                        },
                    }
                ),
                encoding="utf-8",
            )

            args = SimpleNamespace(
                target=raw_target,
                model_target=model_target,
                target_meta=target_meta,
                geometry=geometry,
                target_packet_out=None,
                target_build_out=None,
            )
            request_payload: dict[str, object] = {}

            with patch("batch_model_select.build_target_ocr_packet") as build_packet:
                target_packet = attach_target_context(request_payload, args)

            build_packet.assert_not_called()
            self.assertEqual(
                target_packet["build_log"]["ocr_status"],
                "skipped_document_canvas_fast_path",
            )
            self.assertEqual(target_packet["completeness"], "needs_target_image")
            self.assertIn("TARGET_CONTEXT_KIND: document_canvas", target_packet["packet_text"])
            self.assertIn("TARGET_IMAGE: attached screenshot", target_packet["packet_text"])
            self.assertIn("red rectangle marks the focused caret/selection line", target_packet["packet_text"])
            self.assertIn("blue rectangle marks the nearby document/canvas region", target_packet["packet_text"])
            self.assertNotIn("INSERTION_CONTRACT", target_packet["packet_text"])
            self.assertNotIn("COMPLETENESS:", target_packet["packet_text"])
            self.assertIn("Title slide", target_packet["packet_text"])
            self.assertEqual(
                request_payload["target_context"]["annotation_metadata"]["annotated_target"],
                "target_annotated.request.jpg",
            )

    def test_document_canvas_fast_path_omits_empty_probe_preview(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target_meta = root / "target_metadata.json"
            geometry = root / "geometry.json"
            target_meta.write_text(
                json.dumps(
                    {
                        "target_mode": "document_canvas",
                        "target_copy_probe": {"status": "empty", "string_preview": ""},
                    }
                ),
                encoding="utf-8",
            )
            geometry.write_text(json.dumps({"status": "ok"}), encoding="utf-8")
            args = SimpleNamespace(
                target=root / "target.png",
                model_target=root / "target_annotated.request.jpg",
                target_meta=target_meta,
                geometry=geometry,
                target_packet_out=None,
                target_build_out=None,
            )

            target_packet = attach_target_context({}, args)

            self.assertNotIn("TARGET_COPY_PROBE_TEXT_PREVIEW", target_packet["packet_text"])

    def test_document_canvas_without_model_target_still_skips_ocr_and_attaches_raw_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target_meta = root / "target_metadata.json"
            geometry = root / "geometry.json"
            raw_target = root / "target.png"
            target_meta.write_text(
                json.dumps(
                    {
                        "target_mode": "document_canvas",
                        "target_copy_probe": {
                            "status": "ok",
                            "plain_text_bytes": 11,
                            "string_preview": "Title slide",
                        },
                    }
                ),
                encoding="utf-8",
            )
            geometry.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "annotation_metadata": {
                            "status": "degenerate_document_canvas_anchor",
                            "annotation_confidence": "low",
                        },
                    }
                ),
                encoding="utf-8",
            )

            args = SimpleNamespace(
                target=raw_target,
                model_target=None,
                target_meta=target_meta,
                geometry=geometry,
                target_packet_out=None,
                target_build_out=None,
            )
            request_payload: dict[str, object] = {}

            with patch("batch_model_select.build_target_ocr_packet") as build_packet:
                target_packet = attach_target_context(request_payload, args)
                item = target_image_content_item(request_payload, target_packet, args)

            build_packet.assert_not_called()
            self.assertEqual(
                target_packet["build_log"]["ocr_status"],
                "skipped_document_canvas_fast_path",
            )
            self.assertEqual(target_packet["build_log"]["model_target_path"], str(raw_target))
            self.assertEqual(item["path"], raw_target)
            self.assertFalse(item["preprocessed"])
            self.assertEqual(
                request_payload["target_context"]["model_target_image"]["source"],
                "raw_target",
            )
            self.assertIn("TARGET_IMAGE: attached raw screenshot", target_packet["packet_text"])
            self.assertIn("no red/blue annotation was drawn", target_packet["packet_text"])
            self.assertNotIn("INSERTION_CONTRACT", target_packet["packet_text"])
            self.assertNotIn("COMPLETENESS:", target_packet["packet_text"])

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
            model_target=Path("/tmp/target_annotated.request.jpg"),
        )

        item = target_image_content_item(
            request_payload,
            {"completeness": "needs_target_image"},
            args,
        )

        self.assertEqual(item["type"], "image")
        self.assertEqual(item["path"], Path("/tmp/target_annotated.request.jpg"))
        self.assertTrue(item["preprocessed"])
        self.assertEqual(item["mime_type"], "image/jpeg")
        self.assertEqual(
            request_payload["target_context"]["model_target_image"]["source"],
            "annotated",
        )
        self.assertEqual(
            request_payload["target_context"]["model_target_image"]["artifact"],
            "target_annotated.request.jpg",
        )
        self.assertNotIn(
            "path",
            request_payload["target_context"]["model_target_image"],
        )

    def test_target_image_item_does_not_treat_png_model_target_as_preprocessed(self) -> None:
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

        self.assertFalse(item["preprocessed"])
        self.assertIsNone(item["mime_type"])

    def test_target_image_item_skips_sufficient_packets(self) -> None:
        request_payload = {"target_context": {"mode": "strict_field"}}
        args = SimpleNamespace(target=Path("/tmp/target.png"), model_target=None)

        item = target_image_content_item(request_payload, {"completeness": "sufficient"}, args)

        self.assertIsNone(item)
        self.assertNotIn("model_target_image", request_payload["target_context"])

    def test_prompt_allows_rich_image_fragment_selection(self) -> None:
        self.assertIn("rich image-fragment handle", PROMPT)
        self.assertIn("whole slide/layout selection", PROMPT)
        self.assertIn("paste_items", PROMPT)
        self.assertIn("source_groups", PROMPT)
        self.assertIn("visual_tags are local Vision classifications", PROMPT)
        self.assertIn("Do not generate text for copy-through paste", PROMPT)
        self.assertIn("inspect the attached target screenshot", PROMPT)
        self.assertIn("red rectangle as the focused caret/selection line", PROMPT)

    def test_model_runner_preprocessed_image_skips_sips(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            image_path = Path(tmp) / "target_annotated.request.jpg"
            image_path.write_bytes(b"fake jpeg bytes")

            with patch("model_runner.prepare_request_image") as prepare_request_image:
                prepared = _prepare_content_items(
                    {},
                    [
                        {"type": "text", "label": "REQUEST", "text": "{}"},
                        {
                            "type": "image",
                            "key": "target",
                            "label": "TARGET_IMAGE",
                            "path": image_path,
                            "preprocessed": True,
                            "mime_type": "image/jpeg",
                        },
                    ],
                )

            prepare_request_image.assert_not_called()
            self.assertEqual(prepared["images"]["target"]["status"], "preprocessed")
            self.assertEqual(prepared["inputs"]["target_image_bytes"], len(b"fake jpeg bytes"))

    def test_run_log_out_writes_file_without_stdout_contamination(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            request = root / "batch-request.model.json"
            settings = root / "settings.json"
            run_log = root / "selector-run-log.json"
            request.write_text(json.dumps({"allowed_handles": ["item_1"], "items": []}), encoding="utf-8")
            settings.write_text(json.dumps({"provider": "gemini"}), encoding="utf-8")

            argv = [
                "batch_model_select.py",
                "--request",
                str(request),
                "--settings",
                str(settings),
                "--run-log-out",
                str(run_log),
            ]
            stdout = io.StringIO()
            with patch.object(sys, "argv", argv), patch("batch_model_select.load_runtime_env"), patch(
                "batch_model_select.resolve_runtime_settings",
                return_value={"provider": "gemini", "api_key": "fake"},
            ), patch(
                "batch_model_select.generate_completion",
                return_value={
                    "output_text": '{"paste_items":[{"type":"handle","handle":"item_1"}]}',
                    "run_log": {
                        "timings": {"model_latency_ms": 12.3},
                        "response": {"metadata": [{"inline_bytes": b"abc"}]},
                    },
                },
            ), contextlib.redirect_stdout(stdout):
                exit_code = main()

            self.assertEqual(exit_code, 0)
            self.assertEqual(
                stdout.getvalue().strip(),
                '{"paste_items":[{"type":"handle","handle":"item_1"}]}',
            )
            self.assertEqual(
                json.loads(run_log.read_text(encoding="utf-8"))["timings"]["model_latency_ms"],
                12.3,
            )
            self.assertEqual(
                json.loads(run_log.read_text(encoding="utf-8"))["response"]["metadata"][0]["inline_bytes"],
                {"length": 3, "type": "bytes"},
            )

    def test_wait_on_stdin_emits_ready_and_runs_single_request(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            request = root / "batch-request.model.json"
            request.write_text(json.dumps({"allowed_handles": ["item_1"], "items": []}), encoding="utf-8")
            worker_payload = {"request": str(request)}
            argv = ["batch_model_select.py", "--wait-on-stdin"]
            stdout = io.StringIO()
            stdin = io.StringIO(json.dumps(worker_payload) + "\n")

            with patch.object(sys, "argv", argv), patch.object(sys, "stdin", stdin), patch(
                "batch_model_select.load_runtime_env"
            ), patch(
                "batch_model_select._warm_caches"
            ), patch(
                "batch_model_select.resolve_runtime_settings",
                return_value={"provider": "gemini", "api_key": "fake"},
            ), patch(
                "batch_model_select.generate_completion",
                return_value={"output_text": '{"paste_items":[{"type":"handle","handle":"item_1"}]}', "run_log": {}},
            ), contextlib.redirect_stdout(stdout):
                exit_code = main()

            lines = stdout.getvalue().strip().splitlines()
            self.assertEqual(exit_code, 0)
            self.assertRegex(lines[0], r"^READY \d+$")
            self.assertEqual(lines[1], '{"paste_items":[{"type":"handle","handle":"item_1"}]}')

    def test_wait_on_stdin_rejects_missing_request_path(self) -> None:
        argv = ["batch_model_select.py", "--wait-on-stdin"]
        stdin = io.StringIO("{}\n")
        stderr = io.StringIO()

        with patch.object(sys, "argv", argv), patch.object(sys, "stdin", stdin), patch(
            "batch_model_select.load_runtime_env"
        ), patch("batch_model_select._warm_caches"), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            exit_code = main()

        self.assertEqual(exit_code, 2)
        self.assertIn("missing required 'request'", stderr.getvalue())

    def test_wait_on_stdin_times_out_without_consuming_forever(self) -> None:
        argv = ["batch_model_select.py", "--wait-on-stdin"]
        stdout = io.StringIO()

        with patch.object(sys, "argv", argv), patch("batch_model_select.load_runtime_env"), patch(
            "batch_model_select._warm_caches"
        ) as warm_caches, patch(
            "batch_model_select.select.select",
            return_value=([], [], []),
        ), contextlib.redirect_stdout(stdout):
            exit_code = main()

        self.assertEqual(exit_code, 0)
        warm_caches.assert_called_once()
        self.assertRegex(stdout.getvalue().strip(), r"^READY \d+$")


if __name__ == "__main__":
    unittest.main()
