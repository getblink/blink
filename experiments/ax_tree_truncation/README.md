# AX Tree Truncation Probe

Offline harness for testing AX-tree budget strategies before changing
`WindowAXTreeCapture`.

The production path currently emits a flat indented AX tree, then the server
keeps the first `AX_TREE_MAX_CHARS` characters as a backstop. That is cheap, but
on very large scroll surfaces it can preserve the top of the tree and drop the
focused or recently visible region. This probe compares that baseline with a
focus/mouse-anchored selection window using saved request artifacts.

## Usage

Run from the repo root:

```bash
python3 experiments/ax_tree_truncation/truncation_probe.py \
  --input .context/attachments/YihSzp/pasted_text_2026-05-30_01-38-56.txt \
  --budget 8000 \
  --anchor-text "Terminal input" \
  --out .context/ax-tree-truncation-probe
```

Inputs can be:

- a Gemini request JSON containing a text part with `<ax_tree>...</ax_tree>`
- a Blink request envelope JSON containing `ax_tree`
- a raw AX tree text file

The probe first folds tandem duplication (the shipped `collapseTandemRuns` step:
browser tab strip / toolbar that Chromium emits several times per window),
mirroring the production order, then runs the windowing strategies on the
collapsed tree. It also re-folds embedded-newline continuation lines so a saved
serialized tree backtests the same node array the Swift capture folds in memory.

The output directory contains:

- `summary.md` with the collapse reclaim and metrics for `head`, `tail`, and `anchor` strategies
- `report.json` with the same metrics (including the `collapse` block) in machine-readable form
- `collapsed.txt` with the tree after duplication folding
- `head.txt`, `tail.txt`, and `anchor.txt` with the selected tree text

Use `--anchor-index`, `--anchor-ratio`, or `--anchor-text` to simulate where the
future product anchor would land. `--after-ratio` controls how much of the
remaining anchored budget is biased below the anchor; the default is `0.65`.
