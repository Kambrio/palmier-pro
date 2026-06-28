---
name: montage-editing
description: "Edit existing footage into a coherent, emotionally paced story inside Palmier Pro. Use when the user asks to assemble, cut, restructure, tighten, or 'tell a story' from their clips — montage building, sequencing shots, choosing a story structure, beat planning, B-roll placement, J/L cuts, match cuts, and music-synced pacing. Reads the Shot Library to understand the footage, then applies edits through the Palmier MCP tools. Pairs with the story-development skill for planning the arc on the story graph."
---

# Montage & Editing

Turn a pile of raw footage into a story. This skill is editing craft grounded in Palmier's tools: it reads what the footage *shows* (the Shot Library), picks a structure, then sequences and trims clips on the timeline.

## First: understand the footage

Never edit from filenames. Before sequencing:

1. Call `get_timeline` (fps, tracks, clips) and `get_shot_library`.
2. If `unanalyzedCount > 0`, call `analyze_footage` — it samples 3 frames per video and runs on-device vision + transcript, producing per-shot **name, description, shot size, people count, identity group, action, and labels**.
3. Read each shot's `shotSize`, `action`, `scene`, `people`, `personGroup`, `transcript`, and `labels`.

**Respect labels.** Never place footage labeled `skip`. Lead the story with `key` shots. Footage sharing a `personGroup` features the same person — use it for continuity. Record decisions back with `set_shot` (give footage clear names; tag `key`/`skip`/custom).

## Pick a structure

Match the structure to the material and the user's intent. Default to **Hook → Build → Payoff** when unsure.

- **Hook → Build → Payoff** — short-form default. Hook (1–3s, strongest visual/claim) → Build (70–80%, escalating, vary every 3–5s) → Payoff (reveal/resolution).
- **Three-act** — setup (inciting moment) → confrontation (rising obstacles, midpoint turn) → resolution (climax, closure).
- **Kishōtenketsu** — intro → development → **twist** (unexpected shift, no conflict needed) → reconciliation. Great for quiet, reflective, cinematic-life pieces.
- **Story Circle (Harmon)** — you → need → go → search → find → take → return → change. Character-driven vlogs/mini-docs.
- **Problem → Agitation → Solution** — tutorials, product, persuasion.
- **Before / After** — transformation content; often show the "after" in the hook.

## Beat template — cinematic travel / life vlog

A reusable spine (compress or drop beats by length):

1. **Cold-open hook** — 1–2 striking shots, no dialogue, music builds. J-cut into it.
2. **Establishing** — wide location shots; slower; calm narration/text. Answer where/when/why.
3. **Discovery** — montage, detail → medium → wide; music-synced; match cuts.
4. **Rising moments** — varied activity + reaction + cutaways; energy builds; L/J cuts.
5. **Reflection** — one held shot (3–5s), intimate voiceover, music pulls back.
6. **Climax** — the earned peak moment; crescendo; hold the frame; slow-mo optional.
7. **Resolution** — wind-down b-roll; tone mirrors the open; music resolves.
8. **Outro** — short branding / CTA; clean fade.

## Sequencing principles

- **In medias res** — open on the single strongest clip (most intense/beautiful/emotional) before any context, then cut back to setup.
- **Therefore / but, not and-then** — order beats so each is a *consequence* of the last. Cause-and-effect sustains momentum; a flat "and then… and then" loses viewers.
- **Cut clutter** — drop clips that don't serve the story, even technically good ones. Tighten for retention.
- **Retrospective voiceover** — use VO/sit-down reflection to unify scattered clips, bridge time jumps, and add what the footage can't say (stakes, feelings, lessons). Let music + natural sound carry purely visual sequences.
- **Shot variety** — never two same-size shots back to back. Cycle wide → medium → close-up → detail. Use the Shot Library's `shotSize` to enforce this.
- **Establishing → detail** — open a scene wide (context), then tighten (focus, emotion), then re-establish when context shifts.
- **Match cuts** — bridge shots by shared shape, motion, or composition (door opens → window opens; circle → circle).
- **J-cut / L-cut** — bring the next shot's audio in *early* (J) or carry the previous audio *over* the next visual (L) for smooth, layered transitions. Plan these from clip audio.
- **Music-synced pacing** — cut on downbeats for energy; quick cuts (0.3–0.8s) in builds, medium (1–2s) in narrative, held (3–5s) for emotion. Vary cut lengths — even rhythm reads as amateur.
- **Continuity** — keep color/tone consistent across a sequence; use `personGroup` for who-appears-where; keep a subject's coverage together.

## Applying it through Palmier tools

Plan in shots, then execute with the timeline tools:

- `add_clips` / `insert_clips` — place shots in beat order on a video track. Use `trimStartFrame`/`trimEndFrame` to pull the strongest moment from a clip (find it via `inspect_media` frames or the Shot Library frame timestamps).
- `ripple_delete_ranges` / `remove_words` — tighten: cut dead air, filler, and weak takes. `remove_words` is transcript-driven for talking-head footage.
- `split_clips` / `move_clips` / `set_clip_properties` — refine cut points, reorder, set speed (slow-mo for beauty/climax), opacity, volume.
- `sync_audio` — align dual-system or music to the cut.
- `add_texts` / `add_captions` — titles, chapter cards, and spoken subtitles.
- `apply_color` / `apply_effect` / `stabilize_clips` — finishing: consistent grade, looks, and locked-down handheld.

## Workflow

1. `get_timeline` + `get_shot_library` (analyze if needed).
2. Choose a structure; map beats to specific shots by their Shot Library description/labels (skip `skip`, lead with `key`).
3. (Optional) lay the plan out on the **story graph** — see the story-development skill — so the user can see and steer it.
4. Build the cut: place beat shots with `add_clips` (trim to the best moment), tighten with `ripple_delete_ranges`/`remove_words`, layer music and titles.
5. Name and tag shots you used with `set_shot`; tell the user the structure you chose and which `key` shots carry it.

Keep edits decisive — they're undoable. Lead with the result, not the process.
