# Demo Fixture Plan

Checklist of fixtures to capture and validate for the upcoming Blink demos.
Each demo follows the same pitch: **one source, multiple targets, each target
gets a meaningfully different paste**. The "aha" is that the destination
changes the meaning of the clipboard, not that autofill exists.

See also:

- `README.md` — repo entrypoint and quickstart
- `CLAUDE.md` — repo layout and implementation guide
- `docs/MANUAL_COPY_PASTE_PLAYBOOK.md` — what a good source/target screenshot
  should contain
- `docs/EXPERIMENT_LOG.md` — log each captured demo's sweep results here
- `scratchpad/README.md` — capture + sweep tooling
- `.context/plans/demo-portfolio-for-ai-copy-paste.md` — full rationale (this
  directory is gitignored; keep this doc in sync if priorities change)

## Per-fixture capture protocol

For every fixture listed below:

1. Start `./capture`; `ctrl+shift+c` on the source window, then `ctrl+shift+v`
   on the target field.
2. Inspect `scratchpad/fixtures/<id>/fixture.json`.
3. Confirm `target_metadata.status != "not_found"` and that at least one of
   `focused_value` / `focused_description` / `focused_label` is populated. If
   they are all null, click explicitly into the field and recapture —
   otherwise the model falls back to image-only and demo outcomes get noisy.
4. After capturing all fixtures for a demo, sweep them:
   ```bash
   ./sweep \
     --fixtures 'scratchpad/fixtures/<demo-slug>-*' \
     --configs  'scratchpad/eval_configs/flash-lite-low-minimal.json' \
     --out      scratchpad/sweeps/<demo-slug>
   ```
5. Review `compare.html` + `summary.md`. Flag any cell that looks wrong
   before showing any audience.
6. Practice each live demo end-to-end at least twice.

Fixtures on the audit list below use `<demo-slug>-<role>` naming so the sweep
glob in step 4 picks them up cleanly.

---

## Demo 1 — Same clipboard, three apps (LIVE)

One flight-confirmation source, three different targets, three different
correct outputs. This is the strongest live "aha".

Source:

- [ ] `demo1-flight-source` — flight confirmation email open in Gmail
  (browser). Needs confirmation number, airline code, route, and time visible.

Targets (web-only — native macOS AX is weak for several apps in the fixture
audit, so we stick to browser fields for reliability):

- [ ] `demo1-calendar-target` — Google Calendar new-event title field.
  Expect: `SFO → JFK · UA1234`.
- [ ] `demo1-keep-target` — Google Keep new-note body (or Notion / Obsidian
  web note). Expect: full structured trip summary.
- [ ] `demo1-slack-target` — Slack web compose, framed as a message to a
  coworker. Expect: casual `landing JFK Tue 3:45pm — confirmation ABC123`.

**Budget:** ~5s × 3 pastes ≈ 15s latency on stage. Narrate through it.

**iMessage note:** iMessage native was the original pick; it got dropped
because native macOS apps frequently return weak or null AX metadata.
Test it cold once — it may still work via TARGET_IMAGE alone — but Slack
web is the safer default.

## Demo 2 — Messy text → clean fields (LIVE)

Inference, not extraction: `3p` → time, `tmrw` → date.

Source:

- [ ] `demo2-scratchnote-source` — a scratch note in Notes or a Slack DM:
  `call the cust tmrw 3p, (415) 555-1234, sarah chen from acme`.

Targets (CRM-style web form — prefer Airtable or a hand-built HTML form for
the most forgiving format handling; fall back to HubSpot free trial only if
the other options break):

- [ ] `demo2-crm-name-target` — `Name`. Expect: `Sarah Chen`.
- [ ] `demo2-crm-phone-target` — `Phone`. Expect: format matches the visible
  placeholder (e.g. `415-555-1234`).
- [ ] `demo2-crm-date-target` — `Follow-up date`. Expect: tomorrow's date in
  the form's format.

## Demo 3 — Job app autofill walkthrough (RECORDED)

A single source feeds 8–12 fields. Recorded so the ~5s waits can be sped up
4× in editing.

Source:

- [ ] `demo3-resume-source` — resume screenshot or LinkedIn profile page.

Targets (YC application form — the existing `*-microsoft-edge-axtextarea`
fixture already validates this path works end-to-end):

- [ ] `demo3-yc-name-target`
- [ ] `demo3-yc-email-target`
- [ ] `demo3-yc-links-target`
- [ ] `demo3-yc-built-target` — "What have you built?"
- [ ] `demo3-yc-why-target` — "Why this idea?"
- [ ] (add remaining form fields as needed)

**Production notes:** keep the source in picture-in-picture so viewers see
only the target changing. Voiceover the narration.

## Demo 4 — Email → structured fields (RECORDED)

A cherry-pickable, low-risk ~60s X clip aimed at dev-tool builders.

Source:

- [ ] `demo4-support-email-source` — a customer support email thread (Gmail
  screenshot).

Targets (Linear or GitHub issue web form):

- [ ] `demo4-issue-title-target` — concise bug summary.
- [ ] `demo4-issue-description-target` — structured repro steps + context.
- [ ] `demo4-issue-priority-target` — inferred severity (only if the field
  is text-input; skip if it's a fixed dropdown).

---

## Deferred / not blocking these demos

- **Mid-typing completion as its own demo** — unlocked by the
  `normalize_for_paste` overlap-trim. Interesting, but scope creep for the
  POC.
- **Auto-paste** (simulated `cmd+V` with clipboard save/restore) — only
  worth doing if a specific demo requires it.
- **Multimodal few-shot examples** — escalate only if text-only examples
  fail to teach tone-shifting on demo 1's casual paste.
- **5th text example for partial completion** — only add if sweep results
  show the model repeating prefixes despite the prompt instruction and
  the post-processing layer.
