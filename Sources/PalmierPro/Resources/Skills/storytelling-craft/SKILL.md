---
name: storytelling-craft
description: "Storytelling theory and emotional craft for video: emotional spine, character/desire/conflict/change, story structures, visual storytelling in sequences, genre patterns, and long-form three-act structure. Use when the user asks why a story feels flat, how to find a video's emotional core, about character arcs or structure, visual storytelling, or how to make viewers care — the WHY/HOW of story, not hooks, production, or templates."
---

# Storytelling Craft

The principles that make video stories resonate — character, desire, conflict, change — and how to apply them across formats, niches, and languages. Even a 45-second short needs an emotional arc; a vlog without an inner conflict is just pretty footage.

**Language & voice:** explain and give examples in the user's language; keep craft terms (emotional spine, cold open, payoff) in English where they clarify.

**Does NOT cover:** hooks/CTAs/retention tricks (`video-hooks`), beat outlines/templates (`video-scripting`), titles (`write-metadata`).

## 1. The emotional spine
Viewers stay because they care about a person with a desire facing friction. Answer four questions *before* shooting/editing:

| Question | What it establishes |
|----------|---------------------|
| **Who is the character?** | Emotional anchor (you, a companion, a local, the subject of a story) |
| **What do they want today?** | Desire / direction |
| **What stands in their way?** | Conflict / friction (weather, a delay, fear, a barrier, danger) |
| **How are they changed by the end?** | Transformation / payoff |

This **desire → conflict → change** arc works for a 12-minute film and a 45-second short alike. A beautiful image earns the click; the emotional arc earns the watch-through.

## 2. Story structures
**A. Hero's micro-journey** (vlogs & shorts, any length):
1. Open with the payoff or problem (hook) — the brightest/most tense moment.
2. Cut to setup — how did we get here? Context, place, character.
3. Escalate obstacles — each bigger than the last.
4. Climax — the big moment (view, confrontation, decision, discovery).
5. Afterglow — reflection: how did the character change? Tease next / CTA.

**B. "Day in the life" with a spine** (lifestyle/news):
1. Inciting moment — a message, the weather, a task sets the tone ("I woke up and saw that…", not "I woke up").
2. Three anchored beats (morning/afternoon/evening) — each a micro-story with a small conflict or win.
3. Payoff scene — answers the promise from the opening.
4. Reflection — one honest, short moment.

**Key rule:** avoid chronological dumps ("woke up, ate, worked, slept"). Every scene must carry a question — "what happens next?" / "will it work?"

## 3. Visual storytelling
Cinematic ≠ high resolution or color grading. It's **intentional shot design** where each shot carries emotion and meaning.

| Practice | Purpose |
|----------|---------|
| Establishing shots | Orient the viewer in place |
| Character-anchored shots | Show emotion and reaction (mid/close on the face) |
| Detail / B-roll inserts | Texture and atmosphere |
| Motion | Travel *with* the viewer (walking, tracking, push-in/out) |
| Motivated transitions | Cut on action, match motion, match color |

**Think in sequences, not single shots.** Each scene is a mini-story: **arrival** (establishing, first look) → **exploration/struggle** (details, reactions, action) → **leaving/reflection** (closing shot, look back). This works for a 30-second short scene and a 3-minute vlog block.

## 4. Genre patterns (examples — adapt to any niche)
**Travel / cinematic:** cold open → setup (why here, the constraints) → exploration 1 (first impressions, early obstacle) → exploration 2 (deeper human/cultural connection) → payoff (the main highlight) → reflection + next-adventure hook. *The place is a character* — use sound, faces, signage, transport so the viewer feels transported.

**Lifestyle:** opening mood (one tone-setting shot) → stated intention ("today I'm trying to…") → three anchor segments each with a micro-conflict → one honest/vulnerable moment → satisfying close. *Focus on relatability, but always with a question or tension.*

**News-style / field report:** immediate context (visual proof first) → one-sentence "nut graf" (why it matters) → background in 2–3 concise beats → ground-level scenes (real voices, details) → what happens next. *For short-form news explainers:* a bold precise summary hook, on-screen text/overlays (maps, dates, numbers), a forward-looking final line.

## 5. Long-form three-act structure (12–15 min)
| Timing | Section | What happens |
|--------|---------|--------------|
| 0:00–0:30 | **Cold open** | The most dramatic scene from the middle/end. Minimal context. One line hinting at the stakes. |
| 0:30–1:00 | **Micro-intro** | A 3–5s identity beat (or skip). Restate the video's goal in one sentence. |
| 1:00–4:00 | **Act 1 — Setup** | Characters, location, constraints. Maps/text/quick cuts for context. |
| 4:00–10:00 | **Act 2 — Journey** | Trials and micro-wins; alternate dialogue scenes with visual sequences; each obstacle raises stakes. |
| 10:00–13:00 | **Act 3 — Payoff** | Deliver the promised payoff + short reflection. The emotional peak. |
| last 30–45s | **Outro / handoff** | On-screen suggestion to a related video + a value-anchored verbal CTA. |

Setup makes a promise; the journey tests it; the payoff fulfills it (or honestly explains why not). Without this arc, even gorgeous footage feels aimless.

## Quick reference: format → approach
| Format | Storytelling focus | Structure | Emotional core |
|--------|-------------------|-----------|----------------|
| Long-form vlog (12–15m) | Full three-act with complications | Cold open → Setup → Journey → Payoff → Reflection | Transformation through journey |
| Travel short (30–60s) | One micro-journey, one conflict | Hero's micro-journey, compressed | One moment of wonder/surprise |
| My-day vertical (30–60s) | Routine with a tension thread | Day-in-the-life with spine | Relatability + small win |
| News short (30–60s) | Clarity and stakes | Nut graf → context → ground-level → forward | "Why this matters to you" |
| Field report (3–8m) | On-the-ground immersion | Context → background → voices → implications | Understanding through presence |

## Common failures to check for
No conflict (everything goes perfectly) · no transformation (same at the end) · chronological dump without a tension thread · pretty shots with no emotional anchor · a payoff that doesn't match the setup's promise.

## Process
1. Identify the challenge: flat story, wrong structure, or missing emotional core?
2. Answer the four spine questions if not already answered.
3. Match the format to a structure (table above); read the genre pattern that applies.
4. Build the emotional arc *first*, logistics second.
5. Apply visual storytelling as sequences (arrival → exploration → leaving), not isolated shots.
6. For a full plan, combine with `video-scripting` (beat outlines) and `video-hooks` (openings/closings).

## Apply in Palmier
Storytelling is theory, but the arc maps onto the timeline: order clips so each scene reads arrival → exploration → leaving; place the cold open first; reserve the payoff. Use `inspect_timeline` / `get_transcript` to review whether the current cut has a tension thread, and `add_texts` for act/chapter cards that mark structure.
