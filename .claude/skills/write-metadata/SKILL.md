---
name: write-metadata
description: "Generate optimized titles, descriptions, hashtags, and tags for YouTube (Shorts & long-form), TikTok, and Instagram Reels. Use when the user asks to write, improve, or generate a video title, description, caption, hashtags, or tags, or wants packaging/SEO guidance for a video."
---

# Write Video Metadata

Optimized titles, descriptions, hashtags, and tags for any video, niche, or language.

**Language & voice:** write metadata in the video's target language; the formulas/trigger words below are patterns — localize them. Keep within the character limits below regardless of language.

**Pairs with:** `scriptwriter`/`video-hooks` (titles often start from the hook), `video-scripting` (pre-publication checklist).

## Platform limits & hashtag rules
| Platform | Title | Description | Hashtags (in description) | Tags |
|----------|-------|-------------|---------------------------|------|
| YouTube Shorts | 100 chars (≈40 visible) | 5,000 (≈125 visible) | 3–5 | 8–12 Studio tags (~400/500 chars) |
| YouTube long | 100 chars (≈60 visible) | 5,000 | 3–5 | 8–12 Studio tags |
| TikTok | (in caption) | 2,200 incl. hashtags | 3–5 | — |
| Instagram Reels | (no separate title) | 2,200 (≈55 visible) | 3–5 | — |

Optimal title length: **40–50 characters (4–8 words)**.

**Hashtag discipline:** 3–5 per video (formula: 2 niche + 1–2 mid + 1 broad). On YouTube the first 3 hashtags show above the title; **>15 hashtags → YouTube ignores all of them**; excessive counts can flag spam. **No hashtags in the title** (they waste the 100-char limit and lower CTR; the platform detects Shorts by aspect ratio, so no `#Shorts` needed).

**YouTube Studio tags** (hidden): 8–12 long SEO phrases + short keywords filling ~400–450 of the 500 chars; bilingual tags widen reach for travel/global topics; irrelevant tags are ignored — don't spam.

## Title rules
1. Put the main promise in the first ~40 characters.
2. Use concrete numbers, not abstractions.
3. Never open with "Hi everyone" / "Welcome".
4. Clarity beats clickbait (very few viral shorts rely on "power words").

**Formulas:** Numbers ("5 perfect …") · Question ("How to … easily?") · Negative/risk ("Never do this") · Personal ("Now I only use this") · Lifehack ("Do this and in a month …").
**Trigger words (localize):** new, simple, perfect, free, fast, how, only … left, never, easy, secret, proven.

## Description rules
- **Line 1 = the value proposition** (visible before "show more").
- ~200–300 words covering who/what/where/when/why, keywords woven in naturally, CTA included, **3–5 hashtags at the end**.
- **TikTok:** write the caption as a *search query* (TikTok is a search engine) — describe the actual content plainly; on-screen text is also indexed. First line must compel the "more" tap.
- **Instagram Reels:** short captions (30–90 chars) maximize reach; first ~55 chars are the hook; 3–5 hashtags at the end.
- If the video has subtitles/CC, mention it — captions are indexed for search and lift retention.

## Search vs Discover (decide first)
- **Search** — the video answers something people query (tutorials, guides, how-to). Title leads with keywords; description answers the query; tags are search phrases.
- **Discover** — the video attracts via emotion/curiosity in feeds. Title is emotional/curiosity-driven; description intriguing; tags are broad categories.
State which target you're optimizing for, then write accordingly.

## Process
1. Ask which platform(s) and the video topic/content.
2. Decide the optimization target (search vs discover).
3. Write the title(s) within limits — **no hashtags in the title**.
4. Write the description (value-prop line 1, keywords, CTA).
5. Select 3–5 description hashtags (niche + mid + broad).
6. For YouTube, select 8–12 Studio tags (~400/500 chars; bilingual for global topics).
7. Note CC/subtitles in the description if available.
8. Output per platform **with character counts**.

## Apply in Palmier
- **Title / description / hashtags** are export-side metadata — deliver them as text for the user to paste, or write them into the project's export fields where supported.
- **On-screen title text** (a title card that reuses the headline) → `add_texts`.
- Pull the spoken content for keyword/description ideas with `get_transcript`.
