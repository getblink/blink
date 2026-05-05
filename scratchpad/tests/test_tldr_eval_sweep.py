"""Focused tests for the TLDR sweep harness."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRATCHPAD_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = SCRATCHPAD_DIR.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scratchpad.tldr_reply import eval_sweep, import_runs  # noqa: E402


class EvalSweepTests(unittest.TestCase):
    def test_context_text_includes_ocr_packet_text(self) -> None:
        context_text = eval_sweep.context_text_for_packet(
            {
                "status": "ok",
                "source_packet_kind": "native_ocr_paragraphs",
                "packet_text": "Sarah needs the migration estimate by 4pm.",
                "packet_chars": 44,
            }
        )

        self.assertIsNotNone(context_text)
        self.assertIn("ocr_packet", context_text or "")
        self.assertIn("Sarah needs the migration estimate", context_text or "")

    def test_build_ocr_packet_skips_when_config_disabled(self) -> None:
        with mock.patch.object(eval_sweep, "build_native_ocr_source_packet") as mock_ocr:
            packet = eval_sweep.build_ocr_packet({}, Path("/tmp/screenshot.png"))

        self.assertIsNone(packet)
        mock_ocr.assert_not_called()

    def test_raw_ocr_config_disables_band_and_chrome_filters(self) -> None:
        with mock.patch.object(eval_sweep, "build_native_ocr_source_packet") as mock_ocr:
            mock_ocr.return_value = {"status": "ok", "packet_text": "text"}

            packet = eval_sweep.build_ocr_packet(
                {"tldr_include_ocr_packet": True, "tldr_ocr_raw": True},
                Path("/tmp/screenshot.png"),
            )

        self.assertEqual(packet, {"status": "ok", "packet_text": "text"})
        mock_ocr.assert_called_once_with(
            source_path=Path("/tmp/screenshot.png"),
            apply_band_filter=False,
            apply_chrome_filter=False,
        )

    def test_generate_cell_writes_request_image_to_cell_dir(self) -> None:
        class FakeModels:
            def generate_content(self, **kwargs):
                class Response:
                    text = '{"tldr":"Done","suggestions":["A","B","C"]}'
                    usage_metadata = {"prompt_token_count": 10, "total_token_count": 20}

                return Response()

        class FakeClient:
            models = FakeModels()

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            screenshot = root / "fixture" / "screenshot.png"
            screenshot.parent.mkdir()
            screenshot.write_bytes(b"fake-png")
            run_dir = root / "sweep" / "fixture" / "config"
            config = {
                "name": "config",
                "prompt_text": "prompt",
                "settings": {
                    "model": "gemini-3.1-flash-lite-preview",
                    "temperature": 0.2,
                    "max_output_tokens": 512,
                    "media_resolution": "MEDIA_RESOLUTION_LOW",
                },
            }
            with mock.patch.object(eval_sweep, "prepare_request_image") as mock_prepare:
                mock_prepare.return_value = {
                    "bytes_data": b"request-bytes",
                    "mime_type": "image/jpeg",
                    "original_bytes": 8,
                    "request_bytes": 4,
                    "duration_ms": 1,
                    "log": {"request_path": str(run_dir / "screenshot.request.jpg")},
                }

                result = eval_sweep.generate_cell(
                    client=FakeClient(),
                    fixture={"slug": "fixture", "screenshot_path": screenshot},
                    config=config,
                    run_dir=run_dir,
                )

        self.assertEqual(result["status"], "ok")
        self.assertEqual(mock_prepare.call_args.kwargs["dest_dir"], run_dir)

    def test_summary_surfaces_failures_latency_caveat_and_prompt_delta(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir)
            fixture_dir = out_dir / "fixture"
            fixture_dir.mkdir()
            manifest_path = fixture_dir / "tldr_fixture.json"
            screenshot_path = fixture_dir / "screenshot.png"
            manifest_path.write_text("{}", encoding="utf-8")
            screenshot_path.write_bytes(b"image")
            fixture = {
                "slug": "fixture",
                "fixture_dir": fixture_dir,
                "manifest_path": manifest_path,
                "screenshot_path": screenshot_path,
            }
            results = [
                {
                    "fixture": fixture,
                    "config": {"name": "tldr_baseline"},
                    "result": {
                        "fixture_slug": "fixture",
                        "config_name": "tldr_baseline",
                        "status": "ok",
                        "usage": {"prompt_token_count": 100, "total_token_count": 130},
                        "timings": {"total_ms": 10},
                        "inputs": {"image_bytes_compressed": 2000},
                        "output_text": "Baseline",
                        "errors": [],
                        "run_json": out_dir / "baseline.json",
                        "output_txt": out_dir / "baseline.txt",
                    },
                },
                {
                    "fixture": fixture,
                    "config": {"name": "compressed"},
                    "result": {
                        "fixture_slug": "fixture",
                        "config_name": "compressed",
                        "status": "error",
                        "usage": {"prompt_token_count": 105, "total_token_count": 140},
                        "timings": {"total_ms": 12},
                        "inputs": {"image_bytes_compressed": 1200},
                        "output_text": "Failed",
                        "errors": ["rate limited"],
                        "exception": {"type": "TooManyRequests"},
                        "run_json": out_dir / "compressed.json",
                        "output_txt": out_dir / "compressed.txt",
                    },
                },
            ]

            summary = eval_sweep.render_summary(
                out_dir=out_dir,
                fixtures=[fixture],
                configs=[
                    {"name": "tldr_baseline", "settings": {"model": "m"}},
                    {"name": "compressed", "settings": {"model": "m"}},
                ],
                sweep_results=results,
            )

        self.assertIn("Failures: `1`", summary)
        self.assertIn("Prompt delta vs baseline", summary)
        self.assertIn("`+5`", summary)
        self.assertIn("cannot prove OCR is hidden behind upload", summary)

    def test_renderers_warn_when_baseline_prompt_delta_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir)
            fixture_dir = out_dir / "fixture"
            fixture_dir.mkdir()
            fixture = {
                "slug": "fixture",
                "fixture_dir": fixture_dir,
                "manifest_path": fixture_dir / "tldr_fixture.json",
                "screenshot_path": fixture_dir / "screenshot.png",
            }
            results = [
                {
                    "fixture": fixture,
                    "config": {"name": "tldr_baseline"},
                    "result": {
                        "fixture_slug": "fixture",
                        "config_name": "tldr_baseline",
                        "status": "error",
                        "usage": None,
                        "timings": {},
                        "inputs": {},
                        "output_text": "Failed",
                        "errors": ["rate limited"],
                        "exception": {"type": "TooManyRequests"},
                        "run_json": out_dir / "baseline.json",
                        "output_txt": out_dir / "baseline.txt",
                    },
                },
                {
                    "fixture": fixture,
                    "config": {"name": "compressed"},
                    "result": {
                        "fixture_slug": "fixture",
                        "config_name": "compressed",
                        "status": "ok",
                        "usage": {"prompt_token_count": 105, "total_token_count": 140},
                        "timings": {},
                        "inputs": {},
                        "output_text": "OK",
                        "errors": [],
                        "run_json": out_dir / "compressed.json",
                        "output_txt": out_dir / "compressed.txt",
                    },
                },
            ]
            configs = [
                {"name": "tldr_baseline", "settings": {"model": "m"}},
                {"name": "compressed", "settings": {"model": "m"}},
            ]

            summary = eval_sweep.render_summary(
                out_dir=out_dir,
                fixtures=[fixture],
                configs=configs,
                sweep_results=results,
            )
            html = eval_sweep.render_compare_html(
                out_dir=out_dir,
                fixtures=[fixture],
                configs=configs,
                sweep_results=results,
            )

        self.assertIn("Baseline errored or omitted prompt-token usage", summary)
        self.assertIn("TooManyRequests: rate limited", summary)
        self.assertIn("Baseline errored - deltas unavailable", html)
        self.assertIn("TooManyRequests: rate limited", html)

    def test_summary_renders_expected_prod_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir)
            fixture_dir = out_dir / "fixture"
            fixture_dir.mkdir()
            expected_path = fixture_dir / "expected.json"
            fixture = {
                "slug": "fixture",
                "fixture_dir": fixture_dir,
                "manifest_path": fixture_dir / "tldr_fixture.json",
                "screenshot_path": fixture_dir / "screenshot.png",
                "expected_path": expected_path,
                "expected": {"tldr": "Production summary", "suggestions": ["A", "B", "C"]},
            }
            results = [
                {
                    "fixture": fixture,
                    "config": {"name": "tldr_baseline"},
                    "result": {
                        "fixture_slug": "fixture",
                        "config_name": "tldr_baseline",
                        "status": "ok",
                        "usage": {"prompt_token_count": 100, "total_token_count": 130},
                        "timings": {},
                        "inputs": {},
                        "output_text": "Sweep summary",
                        "errors": [],
                        "run_json": out_dir / "baseline.json",
                        "output_txt": out_dir / "baseline.txt",
                    },
                }
            ]

            summary = eval_sweep.render_summary(
                out_dir=out_dir,
                fixtures=[fixture],
                configs=[{"name": "tldr_baseline", "settings": {"model": "m"}}],
                sweep_results=results,
            )
            html = eval_sweep.render_compare_html(
                out_dir=out_dir,
                fixtures=[fixture],
                configs=[{"name": "tldr_baseline", "settings": {"model": "m"}}],
                sweep_results=results,
            )

        self.assertIn("#### prod", summary)
        self.assertIn("Production summary", summary)
        self.assertIn("<th>prod</th>", html)
        self.assertIn("Production summary", html)

    def test_html_prod_cell_is_blank_when_expected_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir)
            fixture = {
                "slug": "fixture",
                "manifest_path": out_dir / "tldr_fixture.json",
                "screenshot_path": out_dir / "screenshot.png",
            }
            results = [
                {
                    "fixture": fixture,
                    "config": {"name": "tldr_baseline"},
                    "result": {
                        "fixture_slug": "fixture",
                        "config_name": "tldr_baseline",
                        "status": "ok",
                        "usage": {"prompt_token_count": 100},
                        "timings": {},
                        "inputs": {},
                        "output_text": "Baseline",
                        "errors": [],
                        "run_json": out_dir / "baseline.json",
                        "output_txt": out_dir / "baseline.txt",
                    },
                }
            ]

            html = eval_sweep.render_compare_html(
                out_dir=out_dir,
                fixtures=[fixture],
                configs=[{"name": "tldr_baseline", "settings": {"model": "m"}}],
                sweep_results=results,
            )

        self.assertIn('<td class="prod empty"></td>', html)
        self.assertNotIn("<strong>prod</strong><div class=\"meta\">n/a</div>", html)

    def test_fixture_record_reads_tldr_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            fixture_dir = Path(tmpdir) / "demo"
            fixture_dir.mkdir()
            (fixture_dir / "screenshot.png").write_bytes(b"image")
            (fixture_dir / "tldr_fixture.json").write_text(
                '{"slug":"demo","label":"Demo","captured_at":"now","notes":"","screenshot":"screenshot.png"}',
                encoding="utf-8",
            )

            record = eval_sweep.fixture_record(fixture_dir)

        self.assertEqual(record["slug"], "demo")
        self.assertEqual(record["screenshot_path"], fixture_dir / "screenshot.png")

    def test_fixture_record_loads_expected_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            fixture_dir = Path(tmpdir) / "demo"
            fixture_dir.mkdir()
            (fixture_dir / "screenshot.png").write_bytes(b"image")
            (fixture_dir / "tldr_fixture.json").write_text(
                '{"slug":"demo","screenshot":"screenshot.png"}',
                encoding="utf-8",
            )
            (fixture_dir / "expected.json").write_text(
                '{"tldr":"Prod","suggestions":["A","B","C"]}',
                encoding="utf-8",
            )

            record = eval_sweep.fixture_record(fixture_dir)

        self.assertEqual(record["expected"]["tldr"], "Prod")
        self.assertEqual(record["expected_path"], fixture_dir / "expected.json")

    def test_medium_config_parses(self) -> None:
        base = {
            "model": "gemini-3.1-flash-lite-preview",
            "temperature": 0.2,
            "max_output_tokens": 512,
            "media_resolution": "MEDIA_RESOLUTION_LOW",
        }

        config = eval_sweep.config_record(
            REPO_ROOT / "scratchpad/eval_configs/tldr_jpeg_q70_d1600_med.json",
            base,
        )

        self.assertEqual(config["settings"]["media_resolution"], "MEDIA_RESOLUTION_MEDIUM")
        self.assertEqual(config["settings"]["request_image_max_dimension"], 1600)

    def test_import_runs_happy_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            run_dir = root / "runs" / "20260504-120000"
            run_dir.mkdir(parents=True)
            (run_dir / "screenshot.png").write_bytes(b"image")
            (run_dir / "request.json").write_text(
                '{"frontmost_app":{"name":"Mail"},"focused_context":{"title":"Inbox"}}',
                encoding="utf-8",
            )
            (run_dir / "run.json").write_text(
                '{"started_at":"2026-05-04T12:00:00-07:00","settings":{"media_resolution":"MEDIA_RESOLUTION_MEDIUM","request_image_format":"jpeg"}}',
                encoding="utf-8",
            )
            (run_dir / "response.json").write_text(
                '{"tldr":"Prod","suggestions":["A","B","C"],"model":"m","usage":{"prompt_token_count":1},"duration_ms":42}',
                encoding="utf-8",
            )
            out = root / "fixtures"

            imported = import_runs.import_run(run_dir, out)

            manifest = eval_sweep.load_json(out / run_dir.name / "tldr_fixture.json")
            expected = eval_sweep.load_json(out / run_dir.name / "expected.json")

        self.assertTrue(imported)
        self.assertEqual(manifest["slug"], "20260504-120000")
        self.assertEqual(manifest["label"], "Mail (20260504-120000)")
        self.assertEqual(manifest["capture"]["frontmost_app"]["name"], "Mail")
        self.assertEqual(expected["tldr"], "Prod")
        self.assertEqual(expected["settings"]["media_resolution"], "MEDIA_RESOLUTION_MEDIUM")

    def test_import_runs_skips_schema_drift_with_warning(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            run_dir = root / "runs" / "old"
            run_dir.mkdir(parents=True)
            (run_dir / "screenshot.png").write_bytes(b"image")
            (run_dir / "run.json").write_text(
                '{"response":"old schema text"}',
                encoding="utf-8",
            )
            out = root / "fixtures"
            with mock.patch.object(import_runs, "warn") as mock_warn:
                imported = import_runs.import_run(run_dir, out)

        self.assertFalse(imported)
        self.assertIn("no usable TLDR response", mock_warn.call_args.args[0])

    def test_import_runs_warns_on_empty_scratchpad_capture(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            run_dir = root / "runs" / "scratch"
            run_dir.mkdir(parents=True)
            (run_dir / "screenshot.png").write_bytes(b"image")
            (run_dir / "meta.json").write_text(
                '{"capture":{"status":"ok","bbox":{"x":0,"y":0,"width":100,"height":100}}}',
                encoding="utf-8",
            )
            (run_dir / "response.json").write_text(
                '{"tldr":"Prod","suggestions":["A","B","C"]}',
                encoding="utf-8",
            )
            with mock.patch.object(import_runs, "warn") as mock_warn:
                imported = import_runs.import_run(run_dir, root / "fixtures")

        self.assertTrue(imported)
        self.assertIn("importing without frontmost_app/focused_context", mock_warn.call_args.args[0])

    def test_import_runs_refuses_shared_pool_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            shared = Path(tmpdir) / "shared"
            shared.mkdir()
            old_shared = import_runs.SHARED_POOL_ROOT
            import_runs.SHARED_POOL_ROOT = shared
            try:
                with self.assertRaises(ValueError):
                    import_runs.refuse_shared_pool_out(shared / "fixtures")
            finally:
                import_runs.SHARED_POOL_ROOT = old_shared


if __name__ == "__main__":
    unittest.main()
