---
name: video-scripting
description: "Script structures, story beats, chapter outlines, and pre-production planning for common video formats (long-form vlog, my-day vertical, news-style short, how-to). Use when the user asks about scripting a video, beat outlines, chapter structure, story architecture, content pillars, pre-production planning, an editing pipeline, or a per-video / pre-publication checklist."
---

# Video Scripting & Pre-Production

Concrete beat structures and planning checklists for the main video formats — for any topic, niche, or language.

**Language & voice:** output in the user's language; examples are patterns to adapt.

**Pairs with:** `storytelling-craft` (the WHY of structure), `scriptwriter` (full drafts), `video-hooks` (openers/endings), `write-metadata` (titles/descriptions).

## Content pillars (map a niche to formats)
| Pillar | Format | Example |
|--------|--------|---------|
| Flagship stories | 8–15 min long-form + 3–5 shorts | A deep dive + short cut-downs |
| Everyday life | 30–60s my-day verticals | Fast montage + captions |
| News / explainer | 30–90s talking-head or screen-record | "What changed in [year]" |
| Education | 30–90s tips/hacks | "How to [save / do X]" |
| Community | Q&A, stitches, duets | Comment replies, reactions |

## Script structures

### A. Long-form (8–15 min) — chaptered
```
1. Cold open (0:00–0:15)      → a strong moment from later; thread a question
2. Title card + context (0:15–0:30) → who / where / what's at stake
3. Act 1: setup (0:30–3:00)   → first impressions, establishing shots, mood
4. Act 2: chapters (3:00–10:00) → 2–4 chapters, each a titled mini-arc with its
                                  own mini-hook; list as: title · timestamp · one-line promise
5. Act 3: payoff + reflection (10:00–end) → answer the threaded question; call forward
```
The chapter list doubles as **YouTube chapter timestamps** and as **on-timeline chapter cards**.

### B. My-day vertical (30–60s)
```
1. Hook (0–3s)            → strong visual or line
2. Rapid montage (3–25s)  → 5–10 clips, 0.5–1.5s each, overlay text for context
3. Micro-beats (pick 3–5) → wake-up / coffee / commute / work / food / evening
4. Close + soft CTA (25–30s)
```

### C. News-style short (30–90s)
```
1. Cold hook (0–3s)   → surprising stat or viewer-centric angle
2. Context (3–10s)    → one sentence, plain language
3. Three bullets (10–40s) → what changed · who it affects · what to do
4. Actionable close (40–50s) → takeaway or timeline
```

## Pre-production checklist
**Strategic (before any video):** define the objective (growth / conversion / community / test) · choose pillar + format · draft hook and core message (1–2 sentences) · confirm deliverables (long-form + N shorts, thumbnails) · estimate budget.

**Per video:** location/topic research · story beats (open · tension · transformation · payoff) · shot list (must-have A-roll + B-roll) · gear check · time plan (light windows, backups).

## Editing pipeline
1. Offload + label footage by date/topic.
2. Rough select — mark standout hooks, emotional moments, smooth moves.
3. Build the **story spine** — assemble beats in order *before* effects.
4. Add music, sound design, transitions.
5. Add captions and on-screen text (leave space for platform UI).
6. Color-correct → export platform-specific versions.
7. For long-form: identify 3–5 shorts/TikTok cut-downs.

## Pre-publication checklist
- [ ] **Title** reflects the content; main promise in the first ~40 chars (see `write-metadata`)
- [ ] **Description** matches the topic, includes keywords (see `write-metadata`)
- [ ] **Thumbnail** accurate; face + emotion lifts CTR
- [ ] **Opening 1–2s** grab scrolling viewers (cold open / pattern interrupt — see `video-hooks`)
- [ ] **Captions** present (higher watch time; accessibility)
- [ ] **Hashtags** relevant, 3–5 (see `write-metadata`)
- [ ] **Chapters** set for long-form (timestamps in description)
- [ ] **Platform exports** — aspect ratio, resolution, safe zones per platform

## Captions & sound-off design
Large, high-contrast, concise captions; emphasize key words; avoid the bottom ~15% / top ~10% (platform UI). ~85% watch without sound — captions are mandatory.

## Process
1. Ask which format (long-form / my-day / news / how-to) and the topic.
2. Produce the beat outline (or chapter outline for long-form) using the structures above.
3. Add hook suggestions (`video-hooks`) and the relevant checklist.
4. For a full script, hand off to `scriptwriter`; for the emotional arc, `storytelling-craft`.

## Apply in Palmier
- **Chapter cards / section titles / on-screen beats** → `add_texts`, one clip per beat at its start frame.
- **Captions** → `add_captions`.
- **Build the spine** → arrange clips per the beat order using the timeline tools (`add_clips` / `move_clips` / `set_clip_properties`); verify with `inspect_timeline`.
- **Set project format** → `set_project_settings` to match the target aspect ratio/resolution before exporting platform versions.
- **Save the beat / chapter outline as a file** → `save_document(filename, content, format: "md")`. It writes to the project's documents folder (`documents/` inside the .palmier project by default; configurable in Settings → Storage) and shows in the Library's **Documents** tab. For a full caption/subtitle file from the current timeline, use `export_transcript(format: "srt")` (or `"md"`) instead.
