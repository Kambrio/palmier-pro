---
name: scriptwriter
description: "End-to-end scriptwriting workflow for short-form and long-form video: brainstorm ideas, fact-check claims, and write Hook–Body–CTA scripts (with chaptered structure for long videos). Use when the user asks to write or draft a video script or screenplay, brainstorm video ideas, fact-check content, batch-produce scripts, or wants a full idea-to-draft workflow for YouTube, Shorts, Reels, or TikTok."
---

# Scriptwriter

End-to-end workflow for brainstorming, researching, and writing high-retention scripts for YouTube, Shorts, Reels, and TikTok — for any topic, niche, creator, or language.

**Language & voice:** Write in the language and tone the user/project specifies (default: the user's language). The examples below are language-neutral *patterns* — translate and re-voice them to the topic and audience. Keep craft terms (hook, B-roll, CTA, cold open) in English where they clarify.

**Pairs with:** `storytelling-craft` (emotional arc / structure theory), `video-hooks` (openers, retention, endings, loops), `video-scripting` (beat outlines, pre-production), `write-metadata` (titles, descriptions, hashtags).

## Operating principles

1. **Audience-first** — start from the audience, their problem, and the transformation the video promises.
2. **Hook → Value → Action** — the default spine for short-form: HOOK → BODY → CTA.
3. **Accuracy over virality** — every factual claim must be verifiable; flag anything unverified.
4. **System over vibes** — use frameworks and templates, not blank-page improvisation.

## Workflow

### Step 1 — Clarify the brief
Gather or infer (propose sensible defaults for anything missing, then confirm):
- Topic / niche
- Platform & duration (e.g. TikTok 30s, YouTube 10 min)
- Content type (how-to, story, myth-buster, secret-tool, hot take, listicle)
- Target audience (who they are, their pain, what they want)
- Tone (cozy, authoritative, funny, serious)
- Constraints (sponsor, links, off-limits topics, language)

### Step 2 — Audience & angle card
A 3–6 line profile: Who is the viewer and what are they tired of hearing? What transformation does the video promise (from X to Y)? What angle makes *this* video distinct?

### Step 3 — Idea generation
Generate ideas with proven patterns; label each with format, difficulty, series potential, virality:
- **Secret tool:** "Stop using [X], start using this"
- **Big mistake:** "You're losing [Y] because of this mistake"
- **Myth-buster:** "Everything you were told about [Z] is wrong"
- **How-to:** "The simplest way to [goal] in [year]"
- **Story:** "[Time] ago I was [low]. Today [high]. Here's what changed"
- **Listicle:** "5 things I learned doing [X]"
- **Contrarian:** "Why [popular advice] doesn't work"

### Step 4 — Research & fact-checking (for any factual claims)
1. **Inventory claims** — extract every fact, stat, and causal assertion.
2. **Source search** — primary sources first (studies, official data), then trusted outlets; cross-check key facts against multiple independent sources.
3. **Label each claim:** confirmed (+source) / expert consensus / disputed / opinion-or-personal-experience.

**Fact-sheet format:**

| Claim | Source | Type (official/news/blog) | Confidence (high/med/low) |
|-------|--------|---------------------------|---------------------------|

Warn about: claims contradicting authoritative consensus; health/finance/safety claims without sourcing; stats older than ~2 years; opinion phrased as fact.

### Step 5 — Hook variants (write 3–5)
| Pattern | Template |
|---------|----------|
| Question | "What if you could [result] in [time] without [pain]?" |
| Mistake | "You're losing [time/money] because of this mistake in [niche]" |
| Secret | "Stop using [X], start using this" |
| Myth | "Everything you were told about [topic] is wrong" |
| Pain | "If [frustration] sounds familiar, watch to the end" |
| How-to | "Here's the simplest way to [goal]" |
| Story | "[Time] ago I was [low]. Today [high]" |

For each hook also propose the **on-screen text** (shortened) and a **visual** (B-roll / screenshot / prop). See `video-hooks` for more patterns.

### Step 6 — Draft short-form script
Spine: **HOOK (0–3s) → BODY (3–50s) → CTA (2–5s)**. Body formulas: PAS (Problem → Agitate → Solve), Steps (1/2/3), or Before/After/Bridge. Use inline markers: `[pause]`, `[on-screen text: …]`, `[B-roll: …]`, `[pattern interrupt]`.

### Step 7 — Draft long-form script (chaptered)
1. Cold open / pattern interrupt (0:00–0:15)
2. Hook + promise (0:15–0:30)
3. Context + credibility (0:30–1:00)
4. **Chapters** — each a titled segment with its own mini-hook; list them as a chapter outline (title + timestamp + one-line promise) so they double as YouTube chapter markers and on-timeline title cards.
5. Recap + CTA

### Step 8 — Write the CTA
Match the creator's current priority and keep it in-character (not spammy):
- **Engagement:** "Comment [keyword]", "Save this for later"
- **Conversion:** "Link in the description", "Join the challenge"
- **Algorithm:** "Send this to someone who needs it"

Provide 1–2 CTA variants per script. For short-form loops, put the explicit CTA in the caption, not the final seconds (see `video-hooks`).

## Output format (per video)
1. Working title (SEO + curiosity) — see `write-metadata`
2. 3–5 hook variants (spoken + on-screen text + visual)
3. Structural plan (Hook-Body-CTA, or chapter outline for long-form)
4. Full script or talking points (with markers)
5. Fact sheet (claims + sources + confidence)
6. Repurposing suggestions (optional: long-form → Shorts cut-downs)

## Apply in Palmier
When the project is open in Palmier, the agent can place script output straight onto the timeline:
- **Titles, lower-thirds, chapter cards, on-screen text** → `add_texts` (one call, multiple text clips; position via normalized coords).
- **Spoken-line subtitles / captions** → `add_captions` (transcribes audio and places styled caption clips).
- **Chapter cards** → one `add_texts` clip per chapter at the chapter's start frame.
- **Save the script / hooks / fact sheet as a file** → `save_document(filename, content, format: "md")`. It writes to the project's documents folder (a `documents/` folder inside the .palmier project by default; the user can change the location in Settings → Storage) and the saved file appears in the Library's **Documents** tab. Pass the complete text as `content`. Offer to save after producing a full script or a batch.
Draft the script first, confirm with the user, then offer to apply it onto the timeline and/or save it as a file.

## Process
1. Ask: short-form (TikTok/Shorts/Reels) or long-form (YouTube)?
2. Gather the brief (Step 1) — ask only what's missing; propose defaults.
3. Brainstorm batch → idea list (Step 3), then scripts for selected ideas; OR single script → Audience Card → Hooks → Script → CTA.
4. For research-heavy topics, run the fact-check (Step 4) before writing the body.
5. Reference `video-hooks` for hooks/endings, `video-scripting` for structure, `storytelling-craft` for the emotional arc, `write-metadata` for titles.
6. Offer to apply the result in Palmier (see above).
