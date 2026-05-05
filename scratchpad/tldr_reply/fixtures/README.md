# TLDR Fixtures

This folder holds manually captured TLDR screenshot fixtures.

Each fixture lives in a slug-named subfolder:

```text
scratchpad/tldr_reply/fixtures/<slug>/
  screenshot.png
  tldr_fixture.json  # includes top-level display_scale when capture provides it
  expected.json  # optional manual grading anchors
```

Create one with:

```bash
./tldr --save-fixture scratchpad/tldr_reply/fixtures/<slug>
```
