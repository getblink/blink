# Test Fixtures

This directory stores small, sanitized snapshots distilled from manual Blink.app
run bundles. Keep them JSON/text-only unless a test genuinely needs binary
image data.

The goal is to pin the artifact shapes that real dogfood runs produce, while
keeping unit tests portable and independent of `~/Library/Application Support`.
