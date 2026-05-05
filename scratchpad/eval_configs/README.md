# Eval Configs

See also:

- `scratchpad/README.md` for the full capture and sweep workflow
- `README.md` for the repo entrypoint and quickstart

This folder holds small JSON config variants for `eval_sweep.py`.

Each file can override any subset of the Gemini runner settings and may optionally include `prompt_path`.

Files prefixed with `tldr_` are for `scratchpad/tldr_reply/eval_sweep.py`.
They compare native PNG parity, client-side JPEG/downscale variants, and
optional Vision OCR packet injection for the TLDR screenshot flow.
