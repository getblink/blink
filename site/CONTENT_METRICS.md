# Content metrics

The entire measurement system for the content flywheel. One file, updated once a
month, ~5 minutes. No dashboard, no tooling. If this ever wants a cron job or a
database, it's over-built — pull it back.

The trend lives in git history. To read a year of progress, scroll the table.

## Monthly ritual (~5 min)

1. **Google Search Console** → Performance → last 28 days. Record total
   **impressions** and **clicks**. (GSC already folds AI-Overview impressions
   into this total, so it doubles as a directional GEO signal — no separate
   tooling.)
   - Property: `useblink.dev` (already verified via DNS TXT — open Search
     Console with the Google account that owns the property).
2. **Prompt presence.** Paste each prompt in the fixed set below into ChatGPT,
   Claude, and Perplexity. Count how many of the prompts surface Blink in the
   answer (a mention or link counts). Record as `appeared / total`. Don't chase
   precision — directional movement is the whole point.
3. **Append one row** to the log. Done.

## Fixed prompt set

Keep this list stable so month-over-month numbers mean something. Change it
rarely and note the change in the log when you do (a changed denominator breaks
the comparison otherwise). Target ~10 prompts.

1. best screen-aware AI assistant for Mac
2. how do I stop AI agents from losing context
3. tool that reads my screen and drafts replies
4. how to manage multiple Claude Code sessions at once
5. local-first AI assistant for macOS
6. AI autocomplete for the whole desktop, not just the editor
7. what is context loss in AI agents
8. how to handle agent handoffs without losing context
9. Mac app that writes replies based on what's on screen
10. alternatives to Raycast AI for drafting messages

## Log

| month   | articles_live | gsc_impressions | gsc_clicks | prompt_presence | notes |
|---------|---------------|-----------------|------------|-----------------|-------|
| 2026-06 | 1             | —               | —          | —               | blog launched; baseline next month |
