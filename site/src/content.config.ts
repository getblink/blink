import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

// Blog content collection. One markdown file per article under
// src/content/blog/<slug>.md — the filename is the URL slug.
//
// Frontmatter contract (keep this small on purpose):
//   title        — article title, rendered as the <h1> (don't repeat it in the body)
//   description   — one line; powers <meta description>, OG, and the blog index blurb
//   publishedAt   — YYYY-MM-DD; feeds Article schema datePublished + sitemap lastmod
//   cluster       — which topic cluster this belongs to (see CLUSTERS below)
//   related       — optional list of other article slugs to link at the foot.
//                   The cornerstone "vision" post is auto-appended to every
//                   other post, so never list it here (see blog/[slug].astro).
//   draft         — optional; true keeps it out of the build (and the index)
const blog = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/blog" }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    publishedAt: z.coerce.date(),
    // Optional: set when you meaningfully revise a published post. Feeds the
    // Article schema's dateModified (a freshness signal) and shows an
    // "updated" line on the page. Leave unset for unrevised posts.
    updatedAt: z.coerce.date().optional(),
    cluster: z.enum([
      "vision",
      "context-loss",
      "screen-aware",
      "agent-tooling",
    ]),
    related: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
  }),
});

export const collections = { blog };

// Human labels for the cluster slugs, used by the blog index to group posts.
// Declaration order is render order on /blog, so `vision` (the cornerstone
// "what is blink?" manifesto) sits first regardless of publish dates. Add a
// cluster here and to the enum above when a new theme earns one — not before.
export const CLUSTERS: Record<string, string> = {
  vision: "Vision",
  "context-loss": "Context Loss",
  "screen-aware": "Screen-Aware Computing",
  "agent-tooling": "Agent Tooling",
};
