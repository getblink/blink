# Content Playbook

The whole content flywheel in one page. Two flows: **publish a post** and the
**monthly check**. Both are designed to need zero thinking — copy, fill, ship.

## The flywheel (index card)

```
do the work (experiment / benchmark / teardown)
  → write ONE post about what you found
    → push (sitemap + schema + RSS are automatic)
      → cut 1 social post from it
        → once a month: read GSC + run the prompt set
          → the post that moved → write its sequel
```

Bias to simplicity at every step. If a step starts needing a dashboard or a
cron job, it's over-built — pull it back.

---

## Before you start (one-time)

- **Branch off `staging`, not `main`.** `staging` is the trunk where all work —
  including this blog system — lives; `main` lags it between releases, so a post
  branched off `main` may not even have the blog infra (`content.config.ts`,
  `src/pages/blog/`, etc.). See
  [CLAUDE.md → Branches & deploys](../CLAUDE.md#branches--deploys).
- **Install site deps once:** `cd site && npm install`.

---

## Publish a post (~10 min + writing)

### 1. Create the file

```bash
site/src/content/blog/<slug>.md
```

**The filename is the URL.** `measuring-context-loss.md` →
`useblink.dev/blog/measuring-context-loss`. Keep slugs short, hyphenated, and
**stable** — renaming one breaks every existing link to it.

### 2. Paste this frontmatter and fill it in

```markdown
---
title: ""                         # rendered as the <h1> — don't repeat it in the body
description: ""                    # one line; powers <meta>, OG card, blog-index blurb, RSS
publishedAt: 2026-01-01            # YYYY-MM-DD
cluster: context-loss             # one of: context-loss | screen-aware | agent-tooling
related: []                       # optional: other post slugs, e.g. ["what-is-context-loss"]
# updatedAt: 2026-02-01           # add ONLY when you later revise a published post
# draft: true                     # uncomment to keep it out of the build while writing
---

your post body in markdown. start at `##` for sections — the title above is
already the h1. match the lowercase, plain voice of /story.
```

### 3. Write the body

- Start headings at `##` (the title is the `<h1>`).
- Voice: lowercase, plain, specific. Match `/story`. **Specificity beats length.**
- Editing bar (all four should be yes):
  - Would I send this to someone?
  - Does it contain an original observation, number, or teardown?
  - Are claims sourced / measured / demonstrated, or clearly framed as opinion?
  - Are stats and quotes attributed?

### 4. Preview locally

```bash
cd site && npm install   # first time only (skip if you already did it)
npm run dev
# open the URL Astro prints — http://localhost:4321/blog/<slug>
# (if 4321 is busy Astro bumps to 4322/4323, so trust the printed port)
```

### 5. Ship

```bash
git add site/src/content/blog/<slug>.md   # stage ONLY the post — nothing else
git commit -m "post: <slug>"
git push                                   # push your branch, then open a PR
```

A post is content-only — it touches no `server/**`, so it triggers no server
deploy. It goes live by landing on `main` (the Cloudflare **production**
branch); `staging` deploys to the staging site if you want a dress rehearsal.
When it merges to `main`, Cloudflare Pages rebuilds `useblink.dev`
automatically — usually live in 1–2 min. Branch pushes also get a Cloudflare
preview deploy if you want to eyeball it before merging.

> Confirm once that Cloudflare's **production branch is `main`** (Pages →
> project → Settings → Builds & deployments). Everything else (root `site`,
> build `npm run build`, output `dist`) is already set.

### What happens automatically — don't hand-do these

Adding the one markdown file is the whole job. On build you get, for free:

- the URL + page, styled to match the site
- entry on `/blog`, grouped under its cluster, newest-first
- `sitemap-index.xml` updated (so crawlers find it)
- `Article` JSON-LD (author, dates) + canonical + OpenGraph/Twitter card
- `/rss.xml` updated
- related-link titles resolved from the slugs in `related:` (missing or draft
  slugs are silently dropped — no dead links)

### Frontmatter field notes

| field | required | notes |
|---|---|---|
| `title` | ✅ | the `<h1>`; `<title>`/OG get a `— Blink` suffix automatically |
| `description` | ✅ | ~1 sentence, ~150 chars; reused in 4 places, so make it good |
| `publishedAt` | ✅ | `YYYY-MM-DD`; parsed as UTC, displayed as-is |
| `cluster` | ✅ | exactly one of the three in `site/src/content.config.ts` |
| `related` | — | array of other slugs; renders as links at the post foot |
| `updatedAt` | — | set on a real later revision → `dateModified` + an "updated" line |
| `draft` | — | `true` hides it from the build, index, routes, and RSS |

Adding a new cluster: add it to **both** the `z.enum` and the `CLUSTERS` label
map in `site/src/content.config.ts`. Three is plenty for now — don't add a
fourth without a real reason.

---

## Monthly check (~5 min)

The entire measurement system is one file: **[`site/CONTENT_METRICS.md`](../site/CONTENT_METRICS.md)**.

Open it and follow the ritual at the top — it's self-contained:

1. **GSC** → impressions + clicks for the last 28 days
   ([Search Console](https://search.google.com/search-console), property
   `useblink.dev`, already verified). This total folds in AI-Overview
   impressions, so it doubles as your GEO signal.
2. **Prompt presence** → paste the fixed prompt set into ChatGPT / Claude /
   Perplexity, count how many surface Blink, record `appeared / total`.
3. **Append one row** to the log table. Done.

No dashboard, no tooling. The trend lives in git history. If you find yourself
wanting to automate it, that's the signal it's working — not the signal to
build tooling.

---

## The four metrics (that's all)

1. Total posts published
2. GSC impressions
3. GSC clicks
4. Prompt presence rate

We care about **directional movement**, not precise rankings. Resist adding a
fifth.
