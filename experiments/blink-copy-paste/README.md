# Archived Blink Copy-Paste Experiment

This directory preserves the older intelligent copy-paste tester app that
previously lived at repo-root `app/`.

It is kept for fixture replay, historical dogfood evidence, and comparison
against the new flagship Blink app now living at `app/`. Do not treat this as
the shipped product surface unless a task explicitly asks to work on the
archived copy-paste experiment.

Useful checks:

```bash
xcodegen generate --spec project.yml
python3 -m unittest discover python/tests
```

The XcodeGen spec was adjusted for the new location: the local
`pasteboard_logger` dependency now resolves via
`../pasteboard_logger/Sources/PasteboardReplayCore`.
