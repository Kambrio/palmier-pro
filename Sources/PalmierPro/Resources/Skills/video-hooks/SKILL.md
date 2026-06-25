---
name: video-hooks
description: "Hooks, retention techniques, loop structures, endings, CTAs, and engagement phrases for short-form video. Use when the user asks about video hooks, openers, the first 3 seconds, retention, pattern interrupts, endings, loops, replays, CTAs, or engagement phrases for YouTube Shorts, TikTok, or Reels."
---

# Video Hooks & Retention

Hooks, retention devices, and loop structures for short-form video — for any topic, niche, or language.

**Language & voice:** generate hooks/CTAs in the user's language; the templates below are *patterns* to localize.

**Pairs with:** `scriptwriter`, `video-scripting`, `storytelling-craft`.

## Why the first seconds decide everything
- ~50–60% of all drop-offs happen in the first 3 seconds; ~71% decide within 3s whether to keep watching.
- Viewers who reach 3s mostly reach 10s+.
- Subtitles add ~+12% retention; bold captions raise completion (~85% watch without sound).

## Hook types (first 1–3 seconds)
1. **Provocation / contradiction** — "95% of people make this mistake" · "This contradicts everything you've heard"
2. **Curiosity gap** — "90% of experts don't know about this tool" · "Nobody talks about this side of it"
3. **Question** — "What would you do here?"
4. **Result first** — show the stunning result for ~2s, then the process
5. **Mid-action start** — no greeting; open on dramatic action
6. **Personal story** — "Something happened to me today…" · "One mistake cost me thousands of views"
7. **Social proof** — "Over 100K creators use this free tool"

**Production rules:** vary intonation/volume; large readable on-screen text; sync visual + text + audio in the first 2–3s; fast cuts.

## Retention
**Pattern interrupts** — every 3–5s: angle change, text overlay, B-roll, SFX, zoom, animation, speed change. Place a key interrupt around the 25–35s mark.

**The 8–15s survival window** — most shorts lose viewers when initial novelty fades. Use micro-transitions every 3–5s; alternate wide/medium/close to reset attention; cut on the beat of the music. Treat attention as a countdown you reset every few seconds.

**Open loops** — mini-cliffhangers throughout ("But that's not even the worst part…", "Wait for the end and you'll see why"); close loops strategically while opening new ones.

## Endings, loops & replays
The final moments drive rewatches and shares (many platforms count each replay as a view):
- **Loop back** to the opening frame so the video plays seamlessly again — optimal loop length ~20–25s.
- Add a small twist or surprising final line that makes people share.
- Soft CTA aligned with the story (not a generic "like & subscribe").
- Avoid hard endings that signal "video over"; keep energy flowing into the loop.

**Loop techniques:** callback hook (last line echoes opening question) · visual match cut (last frame matches first) · audio continuity across the loop point · cliffhanger · open question the opening "answers".

**Loop creation:** write the ending FIRST → make the opening a question the ending answers → keep under ~25s → match first/last-frame composition → no long CTA at the end (don't waste runtime) → hide the edit point with motion (a swipe, a quick pan).

## CTAs
- Don't say "don't forget to subscribe" at the very end — it breaks the loop.
- Embed the CTA in the story: "Follow if you want more of these."
- Put explicit CTAs in the description/caption, not the final seconds.

## Engagement phrases (localize to the audience)
- **Comment bait:** "Has this happened to you?" · "What would you add?"
- **Save triggers** (a strong algorithm signal): "Save this so you don't forget"
- **Share triggers:** "Send this to someone who needs it"
- **Subscribe triggers:** "Follow for more stories like this"

## Process
1. Determine the need: hook, retention plan, loop, ending, CTA, or engagement phrases.
2. Ask for the topic/content if not provided.
3. Generate 3–5 hook variants using *different* techniques; label each.
4. For a loop: design the ending first, then a matching opener.
5. For a full script: add pattern-interrupt markers and open-loop suggestions; hand off to `scriptwriter`.

## Apply in Palmier
- **On-screen hook text / captions / CTA overlays** → `add_texts` (place the hook text clip at frame 0; CTA near the end). Spoken subtitles → `add_captions`.
- **Loop polish** → use `get_timeline` / `inspect_timeline` to compare the first and last frames for a match cut, and `set_clip_properties` to trim the tail so the loop lands near ~20–25s with no dead "video-over" beat.
