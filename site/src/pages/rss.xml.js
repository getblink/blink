import rss from "@astrojs/rss";
import { getCollection } from "astro:content";

// Blog feed. Auto-discovered via the <link rel="alternate"> in Base.astro and
// listed in the footer. Mirrors the blog index: non-draft posts, newest first.
export async function GET(context) {
  const posts = (await getCollection("blog", ({ data }) => !data.draft)).sort(
    (a, b) => b.data.publishedAt.getTime() - a.data.publishedAt.getTime(),
  );

  return rss({
    title: "Blink Blog",
    description:
      "Notes, benchmarks, and teardowns from building Blink — a Mac assistant that reads your screen and writes the rest.",
    site: context.site,
    items: posts.map((post) => ({
      title: post.data.title,
      description: post.data.description,
      pubDate: post.data.publishedAt,
      link: `/blog/${post.id}/`,
    })),
  });
}
