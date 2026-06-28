---
name: story-development
description: "Develop a video's story interactively on Palmier Pro's story graph — for editing footage the user has ALREADY SHOT into a finished video (post-production, not pre-production planning). A tree of options that starts from the project's direction/genre and branches into structure, acts, and beats, each wired to real footage, captions, and documents. Use when the user wants to figure out what story their footage can tell, explore directions, outline beats, or plan a montage. Generates option nodes from the Shot Library context and links beats to clips. Pairs with montage-editing for executing the cut on the timeline."
---

# Story Development

Help the user shape the story their **already-shot footage** can tell, and turn it into an edited video — collaboratively, on the **story graph**. This is post-production: work only with the clips in the project; never suggest what to film. The graph is a tree of *options*: the root is the project's **direction / genre**, its children are **story structures**, then **acts**, then **beats**, and beats link to the actual **footage, captions, and documents** that fill them.

## Ground the story in the footage

Before proposing directions, know what exists:

1. `get_timeline` and `get_shot_library` (call `analyze_footage` if `unanalyzedCount > 0`).
2. Note the dominant `shotSize`s, `action`s, scenes, people/`personGroup`s, speech, and any `key` shots. The available footage constrains and inspires the story.

## The graph model

- **direction** (root) — the project's genre/format and angle (e.g. "Cinematic travel vlog — a slow day in Lisbon"). Always exactly one root; offer 2–4 direction options first.
- **structure** — a story structure under a direction (Hook→Build→Payoff, three-act, kishōtenketsu, story circle, …).
- **act** — a major movement of the chosen structure.
- **beat** — a concrete moment ("Cold-open hook", "Reflection at sunset"). Beats are what you link footage to.
- **building-block** — a smaller element inside a beat (a specific shot, a line of VO, a title card).

Each node has a `title`, a `summary`, and `links` to project elements (`footage` by mediaRef, `caption`/`document`, or a timeline `clip`). Nodes form parent→child edges.

## Genres (root direction options)

Travel vlog · day-in-the-life · cinematic life · documentary short · tutorial/how-to · product/brand · event recap · montage/highlight · listicle. For each, lead with its arc and what footage it needs — and only propose directions the footage can actually support.

## Recommended structure per direction

Each direction has a **core recommended structure** (returned by `get_story_graph` as `recommendedStructure`, and starred in the UI). Default to it unless the footage suggests otherwise:

- Cinematic life vlog → **Cinematic life** (cold-open → establishing → discovery → rising → reflection → climax → resolution → outro)
- Travel vlog → **Travel story** (hook in medias res → context → goal → obstacles → micro-stories → climax → reflection → outro)
- Day in the life → **Day arc** (hook → morning prep montage → journey → main activity → complication → reflection)
- Documentary short → **Documentary arc** · Tutorial/Product → **Problem → Solution** · Event recap → **Highlight arc** · Montage → **Montage arc**

Other structures (three-act, kishōtenketsu, story circle, before/after, Hook→Build→Payoff) are available as alternatives.

## Research-grounded editing techniques

How creators actually cut travel / day-in-the-life / cinematic footage — apply these when ordering beats and picking clips:

- **In medias res hook** — open on the strongest/most intense clip before any context, then cut back to setup.
- **Context fast** — establish where/why/what-to-expect in under a minute, then get moving.
- **Goal & stakes** — frame the trip/day around an objective or question so there's something to resolve.
- **Therefore / but, not and-then** — order obstacle/beat clips so each is a *consequence* of the last (cause-and-effect keeps momentum).
- **Micro-stories** — build mini-arcs (meeting → interaction → outcome) from encounters and characters in the footage.
- **Retrospective reflection** — use voiceover/sit-down clips to add what was learned or how it felt; plan VO to bridge time jumps and unify scattered clips.
- **Cut clutter** — drop clips that don't serve the story, even good-looking ones; keep retention tight.
- **Chapters / segments** — group into clear segments (Morning prep, Journey, Main activity, Reflection) for longer pieces.
- **Show, don't tell** — let visuals and sound carry it; narrate only what images can't (thoughts, stakes, lessons).

## Working on the graph (MCP tools)

- `get_story_graph` — read the current tree (nodes, kinds, links, parent/child). Call first.
- `add_story_nodes` — create option nodes under a parent. Use it to offer 2–4 **alternatives** at each level (directions, then structures, then beats) so the user can choose by clicking. Seed from genre/structure/beat templates AND from what the footage shows.
- `set_story_node` — edit a node's title/summary, mark it `chosen`, or **link footage/captions/documents** (`addLinks` with a mediaRef/clipId/document) so a beat points at the clips that fill it.
- `remove_story_node` — prune a discarded branch.

The user develops the story by **clicking** nodes in the UI and by **asking you**. When they ask for options, add option nodes; when they pick one, mark it chosen and branch deeper; when a beat is settled, link the specific footage from the Shot Library that fills it.

## Workflow

1. `get_story_graph` (+ `get_shot_library`). If the graph is empty, create the root **direction** node, then add 2–4 direction options grounded in the footage.
2. When the user picks a direction, mark it chosen and add **structure** options; then **acts**; then **beats** — a few alternatives at each step.
3. For each chosen beat, link the best footage (`set_shot` names/labels help you pick; lead with `key`, never `skip`).
4. When the spine is linked end-to-end, hand off to **montage-editing** to build the cut on the timeline, and (optionally) write the outline to a document with `save_document`.

Keep proposals concrete and few (2–4 per branch), always tied to real clips. The point is a story the footage can actually tell.
