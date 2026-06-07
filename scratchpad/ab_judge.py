#!/usr/bin/env python3
"""A/B prompt evaluation for Blink via a blind LLM-judge over the runs corpus.

Generation is byte-faithful to production: this imports the *real* server request
assembly (``server/main.py`` + ``server/gemini.py``) — envelope normalisation,
selected settings, the AX-tree + selection capture suffix, catalog block, and
``prompt_with_context`` — so the ONLY thing that differs between the two arms is
the system prompt (plus optional model / thinking overrides). For each sampled run
it generates the TL;DR + 3 suggestions under prompt A and prompt B, then a blind
judge — shown the actual screenshot + AX text so it can verify grounding, with the
two outputs in randomised order to cancel position bias — picks the better output
overall and per dimension. It aggregates win rates across the corpus.

Cost: 4 Gemini calls per run by default - gen A, gen B, and the judge twice (both
output orders, to neutralize the judge's position bias; a dimension is won only
when both orders agree). --single-order drops it to 3. Generation uses each
captured envelope's prod settings (temperature 1.0 etc.); the judge runs at temp 0.

Run through the scratchpad venv (has server/requirements.txt):
  scratchpad/.venv/bin/python scratchpad/ab_judge.py --b cand_prompt.txt -n 10
  scratchpad/.venv/bin/python scratchpad/ab_judge.py --a server/prompt.txt --b cand.txt \
      --runs-dir ~/Downloads/runs -n 8 --judge-model gemini-3.1-pro-preview
  scratchpad/.venv/bin/python scratchpad/ab_judge.py --a server/prompt.txt --b server/prompt.txt -n 3
      # A==B sanity check: temp-1.0 sampling means outputs differ, so expect a
      # roughly even split and no systematic winner — confirms the harness is fair.

Defaults: A = server/prompt.txt (current shipped), corpus = the live dogfood runs
(~/Library/Application Support/Blink/runs — recent, current envelope format with
AX tree). Use --runs-dir ~/Downloads/runs for the more diverse job-app corpus.
Nothing under server/ is modified.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import random
import sys
import time
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))  # real server modules win

import env_loader  # noqa: E402
import gemini  # noqa: E402
import main  # noqa: E402

DEFAULT_RUNS_DIR = Path.home() / "Library" / "Application Support" / "Blink" / "runs"

JUDGE_RUBRIC = """You are evaluating two candidate outputs from "Blink", a macOS tool that glances at the user's active window — you are shown its screenshot plus the accessibility (AX) text of that window, including off-screen content — and produces a one-line TL;DR plus three paste-ready reply / next-action suggestions.

Both outputs describe the SAME captured screen; they were produced by two different system prompts. Decide which is better for THIS capture. Use the screenshot and AX text as ground truth.

Criteria, in priority order:
1. TL;DR grounding & accuracy: states only what the screen/AX support; no fabricated names, numbers, links, or events.
2. TL;DR signal: surfaces what the user does not already know and would change their next move. On a "catch-up" surface (a thread/page they're returning to) it should be substantive; when the user is the protagonist (their own draft / coding session they just watched) most of what's visible is already known, so a short one-liner is correct, not a failure.
3. Suggestions: specific to what's visible (names, the actual ask/question/bug), paste-ready, the right move (reply / ask / next-step). Generic ("Got it, thanks") only when the capture truly calls for it.
4. Voice: reads like the user would write it (match any visible tone / voice samples).

Be decisive: pick a winner unless the two are genuinely indistinguishable, in which case use "tie".

Output ONLY a JSON object, no prose:
{"overall":"1"|"2"|"tie","tldr":"1"|"2"|"tie","suggestions":"1"|"2"|"tie","voice":"1"|"2"|"tie","reasoning":"<=2 sentences citing concrete evidence"}"""


def load_api_key() -> str:
    try:
        env_loader.load_workspace_env()
    except Exception:
        pass
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        dotblink = Path.home() / ".blink" / ".env"
        if dotblink.exists():
            for line in dotblink.read_text().splitlines():
                line = line.strip()
                if line.startswith("GEMINI_API_KEY="):
                    key = line.split("=", 1)[1].strip()
                    os.environ["GEMINI_API_KEY"] = key
                    break
    if not key:
        sys.exit("GEMINI_API_KEY not found (workspace .env or ~/.blink/.env)")
    return key


def sample_runs(runs_dir: Path, n: int, seed: int) -> list[Path]:
    if not runs_dir.is_dir():
        sys.exit(f"runs dir not found: {runs_dir}")

    def has_image(p: Path) -> bool:
        return any((p / name).exists() for name in (
            "screenshot.jpg", "screenshot.png", "screenshot_0.jpg", "screenshot_0.png"))

    dirs = [p for p in runs_dir.iterdir()
            if (p / "request.json").exists() and has_image(p)]
    if not dirs:
        sys.exit(f"no usable runs (request.json + screenshot) in {runs_dir}")
    random.Random(seed).shuffle(dirs)
    return sorted(dirs[:n], key=lambda p: p.name)


def load_images(run_dir: Path, frame_count: int) -> list[tuple[bytes, str]]:
    images: list[tuple[bytes, str]] = []
    for i in range(max(frame_count, 1)):
        for ext, mime in ((".jpg", "image/jpeg"), (".png", "image/png")):
            p = run_dir / f"screenshot_{i}{ext}"
            if p.exists():
                images.append((p.read_bytes(), mime))
                break
    if not images:
        for name, mime in (("screenshot.jpg", "image/jpeg"), ("screenshot.png", "image/png")):
            p = run_dir / name
            if p.exists():
                images.append((p.read_bytes(), mime))
                break
    return images


def build_call(run_dir: Path, base_prompt: str, model_override: str | None,
               thinking_override: str | None) -> dict:
    """Reproduce server _run_tldr_request assembly for one run, with a swappable
    base prompt. Includes the AX-tree + selection capture suffix (current server)."""
    request = json.loads((run_dir / "request.json").read_text())
    run_meta = {}
    if (run_dir / "run.json").exists():
        run_meta = json.loads((run_dir / "run.json").read_text())

    envelope = main._normalize_request_envelope(request)
    warnings: list[str] = []
    settings = main._selected_settings(envelope, warnings)

    served = (model_override
              or (run_meta.get("response") or {}).get("model")
              or (run_meta.get("runtime") or {}).get("model"))
    if served:
        settings["model"] = served
    if thinking_override:
        settings["thinking_level"] = thinking_override

    bp = base_prompt
    catalog = main._build_catalog_block(settings.get("attachments_catalog") or [])
    if catalog:
        bp = bp.rstrip() + "\n\n" + catalog

    ax_block = main._build_ax_tree_block(envelope.get("ax_tree")).rstrip()
    sel_block = main._build_selection_block(envelope.get("selection")).rstrip()
    suffix = "\n\n".join(b for b in (ax_block, sel_block) if b)

    reroll = envelope.get("reroll_context")
    prompt_text = gemini.prompt_with_context(
        bp, envelope.get("stateful_context"), reroll, envelope.get("style"))

    frame_count = len(envelope.get("frames") or []) or 1
    return dict(
        settings=settings,
        prompt_text=prompt_text,
        suffix=suffix,
        images=load_images(run_dir, frame_count),
        is_followup=isinstance(reroll, dict),
        envelope=envelope,
    )


def generate(call: dict, api_key: str) -> dict:
    if not call["images"]:
        return {"tldr": "", "suggestions": [], "_error": "no images"}
    client = gemini.create_client(api_key, call["settings"])
    final: dict = {}
    for event in gemini.generate_tldr_and_suggestions_streaming(
        client=client,
        settings=call["settings"],
        prompt_text=call["prompt_text"],
        images=call["images"],
        conversation_turns=None,
        user_message_suffix=call["suffix"],
        is_followup=call["is_followup"],
    ):
        if event.get("event") == "final":
            final = event.get("data") or {}
    return final


def fmt_out(o: dict) -> str:
    tldr = (o.get("tldr") or "").strip() or "(empty)"
    sugs = o.get("suggestion_details") or o.get("suggestions") or []
    lines = [f"TL;DR: {tldr}", "Suggestions:"]
    for i, s in enumerate(sugs, 1):
        if isinstance(s, dict):
            tags = ", ".join(s.get("tags", []) or [])
            lines.append(f"  {i}. {s.get('text', '')}" + (f"  [tags: {tags}]" if tags else ""))
        else:
            lines.append(f"  {i}. {s}")
    if len(lines) == 2:
        lines.append("  (none)")
    return "\n".join(lines)


def judge(ctx_call: dict, out1: dict, out2: dict, judge_model: str,
          api_key: str, media_res: str, ax_chars: int) -> dict:
    from google.genai import types
    settings = dict(ctx_call["settings"])
    settings["model"] = judge_model
    client = gemini.create_client(api_key, settings)

    parts = []
    if ctx_call["images"]:
        img, mime = ctx_call["images"][0]
        parts.append(types.Part.from_bytes(data=img, mime_type=mime))
    fa = (ctx_call["envelope"].get("frontmost_app") or {}).get("app_name", "?")
    ax = ctx_call["envelope"].get("ax_tree") or ""
    ctx = f"Frontmost app: {fa}\n"
    if ax:
        ctx += f"\nAccessibility text of the window (ground truth, may be truncated):\n{ax[:ax_chars]}\n"
    ctx += (f"\n--- Output 1 ---\n{fmt_out(out1)}\n\n--- Output 2 ---\n{fmt_out(out2)}\n\n{JUDGE_RUBRIC}")
    parts.append(types.Part.from_text(text=ctx))

    cfg = types.GenerateContentConfig(
        media_resolution=getattr(types.MediaResolution, f"MEDIA_RESOLUTION_{media_res.upper()}"),
        temperature=0.0,
        max_output_tokens=4096,
        response_mime_type="application/json",
        thinking_config=types.ThinkingConfig(thinking_level="low"),
    )
    r = client.models.generate_content(
        model=judge_model,
        contents=[types.Content(role="user", parts=parts)],
        config=cfg,
    )
    text = (r.text or "").strip()
    try:
        return json.loads(text)
    except Exception:
        start, end = text.find("{"), text.rfind("}")
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end + 1])
            except Exception:
                pass
        return {"overall": "parse_error", "_raw": text[:300]}


def main_cli() -> None:
    for name in ("google_genai", "google_genai.models", "httpx"):
        logging.getLogger(name).setLevel(logging.WARNING)
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--a", default=str(REPO_ROOT / "server" / "prompt.txt"),
                        help="prompt A file (default: current server/prompt.txt)")
    parser.add_argument("--b", required=True, help="prompt B file (the candidate)")
    parser.add_argument("--runs-dir", default=str(DEFAULT_RUNS_DIR))
    parser.add_argument("-n", type=int, default=10, help="runs to sample")
    parser.add_argument("--seed", type=int, default=1, help="sample + order seed")
    parser.add_argument("--model", help="override generation model")
    parser.add_argument("--thinking", help="override thinking_level for generation")
    parser.add_argument("--judge-model", default="gemini-3.5-flash")
    parser.add_argument("--judge-media-res", default="medium", help="low/medium/high")
    parser.add_argument("--ax-chars", type=int, default=6000, help="AX text chars shown to judge")
    parser.add_argument("--single-order", action="store_true",
                        help="judge one order only (cheaper, but position-biased)")
    parser.add_argument("--out", default="/tmp/ab_judge_results.json")
    args = parser.parse_args()

    api_key = load_api_key()
    prompt_a = Path(args.a).read_text()
    prompt_b = Path(args.b).read_text()
    runs = sample_runs(Path(args.runs_dir).expanduser(), args.n, args.seed)

    print(f"A = {args.a}")
    print(f"B = {args.b}")
    print(f"corpus = {args.runs_dir}  (n={len(runs)}, seed={args.seed})")
    print(f"judge = {args.judge_model} @ media_res={args.judge_media_res}")
    print("=" * 70)

    dims = ["overall", "tldr", "suggestions", "voice"]
    tally = {d: Counter() for d in dims}
    rows = []
    for idx, run_dir in enumerate(runs, 1):
        try:
            callA = build_call(run_dir, prompt_a, args.model, args.thinking)
            callB = build_call(run_dir, prompt_b, args.model, args.thinking)
            outA = generate(callA, api_key)
            outB = generate(callB, api_key)
            if not (outA.get("tldr") and outB.get("tldr")):
                print(f"[{idx}/{len(runs)}] {run_dir.name}  SKIP (empty generation)")
                continue
            # Dual-order judging neutralizes the judge's position bias: judge both
            # orders; a dimension is won only when both orders name the SAME arm
            # (a position-biased "always pick output 2" cancels to a tie).
            v1 = judge(callA, outA, outB, args.judge_model, api_key, args.judge_media_res, args.ax_chars)
            if args.single_order:
                m = {"1": "A", "2": "B"}
                winners = {d: m.get(v1.get(d), "tie") for d in dims}
                reasoning = v1.get("reasoning", "")
            else:
                v2 = judge(callA, outB, outA, args.judge_model, api_key, args.judge_media_res, args.ax_chars)
                m1, m2 = {"1": "A", "2": "B"}, {"1": "B", "2": "A"}
                winners = {}
                for d in dims:
                    a1, a2 = m1.get(v1.get(d), "tie"), m2.get(v2.get(d), "tie")
                    winners[d] = a1 if (a1 == a2 and a1 in ("A", "B")) else "tie"
                reasoning = f"order1: {v1.get('reasoning','')[:110]} || order2: {v2.get('reasoning','')[:110]}"
            for d in dims:
                tally[d][winners[d]] += 1
            fa = (callA["envelope"].get("frontmost_app") or {}).get("app_name", "?")
            rows.append({"run": run_dir.name, "frontmost": fa, "winners": winners,
                         "reasoning": reasoning,
                         "out_a": {"tldr": outA.get("tldr"), "suggestions": outA.get("suggestion_details") or outA.get("suggestions")},
                         "out_b": {"tldr": outB.get("tldr"), "suggestions": outB.get("suggestion_details") or outB.get("suggestions")}})
            print(f"[{idx}/{len(runs)}] {run_dir.name} ({fa})  overall={winners['overall']}  "
                  f"(tldr={winners['tldr']} sugg={winners['suggestions']} voice={winners['voice']})")
            print(f"        {reasoning[:170]}")
        except Exception as e:
            print(f"[{idx}/{len(runs)}] {run_dir.name}  ERROR {type(e).__name__}: {str(e)[:140]}")
        time.sleep(0.3)

    print("=" * 70)
    judged = sum(tally["overall"].values())
    print(f"JUDGED {judged} runs")
    for d in dims:
        c = tally[d]
        print(f"  {d:12} A={c['A']}  B={c['B']}  tie={c['tie']}"
              + (f"  parse_err={c['?']}" if c['?'] else ""))
    if judged:
        a, b = tally["overall"]["A"], tally["overall"]["B"]
        decisive = a + b
        if decisive:
            print(f"\n  overall: A {a}/{decisive} ({100*a//decisive}%)  vs  B {b}/{decisive} ({100*b//decisive}%)  "
                  f"({tally['overall']['tie']} ties)")
    Path(args.out).write_text(json.dumps({"a": args.a, "b": args.b, "seed": args.seed,
                                          "tally": {d: dict(tally[d]) for d in dims}, "rows": rows}, indent=2))
    print(f"\ndetails -> {args.out}")


if __name__ == "__main__":
    main_cli()
