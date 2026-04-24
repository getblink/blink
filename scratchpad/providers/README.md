# Providers

See also:

- `scratchpad/README.md` for the full capture and sweep workflow
- `README.md` for the repo entrypoint and quickstart

This folder contains thin sweep-only adapters for offline fixture evaluation.

- `gemini.py` keeps the existing Gemini path intact for both old sweep configs and the live runner.
- `openai_sdk.py` reuses the OpenAI Python SDK against OpenAI-compatible endpoints such as OpenRouter, Cloudflare Workers AI, OpenAI direct, and Groq.

`run_gemini_trial.py` stays Gemini-only on purpose. Multi-provider support here applies only to `eval_sweep.py`.
