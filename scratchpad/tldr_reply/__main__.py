from __future__ import annotations

import os
import sys

from scratchpad.env_loader import load_workspace_env

from .runner import TldrReplyApp


def main() -> int:
    load_workspace_env()
    if not os.environ.get("GEMINI_API_KEY"):
        print("Set GEMINI_API_KEY before running ./tldr.", file=sys.stderr)
        return 1

    app = TldrReplyApp()
    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
