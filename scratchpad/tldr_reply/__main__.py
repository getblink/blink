from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from scratchpad.env_loader import load_workspace_env

from .gemini import proxy_settings_from_env
from .runner import TldrReplyApp


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the TLDR screenshot experiment.")
    parser.add_argument(
        "--save-fixture",
        metavar="DIR",
        help="Capture the selected window into DIR/screenshot.png and DIR/tldr_fixture.json without sending a model request.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    load_workspace_env()
    save_fixture_dir = Path(args.save_fixture).expanduser() if args.save_fixture else None
    if save_fixture_dir is None:
        try:
            proxy_settings = proxy_settings_from_env()
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        if proxy_settings is None and not os.environ.get("GEMINI_API_KEY"):
            print("Set GEMINI_API_KEY before running ./tldr.", file=sys.stderr)
            return 1

    app = TldrReplyApp(save_fixture_dir=save_fixture_dir)
    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
