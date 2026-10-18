# EmbeddingGemma 2 Integration — Design

Date: 2026-10-19
Status: approved (design), pending implementation plan
Branch: `feat/embeddinggemma2`

## Purpose

Bring Google's EmbeddingGemma 2 (740M multimodal embedding model, released 2026-10-06) into Palmier Pro as a local, on-device embedding engine so the editor can search, group, and reason over project footage — frames, whole clips, and audio — from natural language. First target project: `hong-kong-visa-run.palmier` (223 Fuji 4K proxies, 3.9 GB, plus 13 voice-over WAVs).

EmbeddingGemma 2 unifies text, image, video, and audio in a single 768-d embedding space (MRL truncation to 512/256/128; near-lossless at 256). Context window is 8,192 tokens: ~29 images at 280 tokens, video at 1 fps capped at 32 frames per pass, audio at 16 kHz mono capped at 30 seconds per pass.

## Model facts

- Checkpoint: `google/embeddinggemma-2` (HF, Apache 2.0 + Gemma Prohibited Use Policy), BF16 safetensors, ~1.5 GB.
- MLX weights: `mlx-community/embeddinggemma-2-8bit` (~800 MB) primary; `-bf16` fallback.
- Runtime: Apple's `mlx-swift-lm` package (v3.32.3+), products `MLXEmbedders` + `MLXVLM`. `EmbedderRegistry.embeddinggemma2` implements the model natively in Swift: text stack loads immediately, vision and audio encoders load lazily on first use. Task prefixes (SearchQuery, Document, Classification, Clustering) are handled by the library.
- Precision rule from the model card: BF16 or FP32 only — never FP16 (NaN risk). MLX runs BF16 natively; the 8-bit quant is the exception we accept for size.
- No sign-in, no API key: fully local, matching the fork's local-first direction.

## Architecture

### 1. `GemmaEmbeddingService` (`Search/Models/`)

One service owning the model lifecycle and every inference call.

- SwiftPM dependency on `mlx-swift-lm`; only `MLXEmbedders` and `MLXVLM` products are linked.
- An actor (not `@MainActor`); all inference off the main actor on Metal. Load runs on a background task; encode calls are serialized through the actor so peak memory stays bounded to one batch.
- Model install reuses the `ModelDownloader` pattern: user-triggered download into Application Support (not bundled, not the repo's `models/` dir), progress state machine identical in shape to `VisualModelLoader.State` (notInstalled / downloading / preparing / ready / failed). Settings toggle lives next to Smart search.
- Public API (all async, all return `[Float]` normalized, full 768-d unless a truncated variant is requested):
  - `embed(text:task:)` — task prefix applied by caller intent (search query vs document).
  - `embed(image:)` — single frame.
  - `embed(videoFrames:)` — ordered frames, ≤32, one interleaved video embedding.
  - `embed(audioChunk:)` — 16 kHz mono PCM chunk ≤30 s.
- Cancellation checked between chunks; encode errors surface as typed errors, never empty-vector success.

### 2. Indexing (`Search/Indexing/GemmaIndexer.swift`, coordinator extension)

Runs after the existing SigLIP sweep inside `SearchIndexCoordinator`, gated on model readiness and user opt-in.

- **Indexes proxy files, keys by source identity.** The proxy URL feeds the sampler/decoder; the store key derives from the source file's path+mtime+size so regenerating proxies never reindexes; when the source is offline (external SSD unmounted) the key falls back to the proxy's own identity. Assets without proxies index their source file as today.
- **Frame level** — reuse `FrameSampler` unchanged (scene-change stream). Each kept frame gets one 768-d vector written into `EmbeddingStore` rows with `model: "embeddinggemma-2"`. The store already keys files and headers per model, so SigLIP and Gemma indexes coexist for the same asset.
- **Clip level** — uniform sample at 1 fps capped at 32 frames, one video embedding per clip, stored in a small sidecar record per asset (`*.clipembed`, same directory and identity rules as `EmbeddingStore`). This is the "what the shot is about" vector used for grouping and agent reasoning.
- **Audio** — for every asset with audio (proxy audio track, plus standalone audio assets such as the project's 13 WAV lines): extract mono 16 kHz via AVFoundation off-main, chunk to ≤30 s, embed each chunk, store rows with time ranges in the same clip-embed sidecar under an `audio` section.
- Concurrency and gating follow `VisualIndexer` behavior: `ExportQueue.shared.waitWhileExportActive()`, cooperative cancellation, progress reported per asset to the coordinator's existing progress surface (`MediaSearchIndexStatus`).
- Idempotence: a header fields check (model, modelVersion, samplerVersion) decides reindex, same contract as SigLIP indexing.

### 3. Search (`Search/Query/`)

- Text queries run through Gemma with the SearchQuery prefix when the model is installed; SigLIP remains the fallback and the second opinion. Rankings merge by reciprocal-rank fusion.
- Result kinds expand from frames to: frames, whole clips, and audio segments — each with time range, asset id, and score.
- Audio-to-footage matching: an embedded voice line's vector versus footage audio-chunk vectors ranks the moments that sound like that line's delivery position — surfaced as placement suggestions.

### 4. Footage analysis (`ShotLibrary/`)

- `FootageGroups`: k-means clustering over clip embeddings in 256-d MRL space. Groups surface as a tab in `ShotLibraryView` with a coverage strip of all clips sorted by cluster.
- Near-duplicate takes: cosine similarity above threshold inside a cluster flags burst-shot groups (the DSCFxxxx bursts in the target project) with a best-take suggestion scored by `ShotLibrary` capture quality.
- Cluster labels come from agent grounding (below), not from a bundled captioner.

### 5. Agent grounding (`Agent/Tools/`)

All through `ToolExecutor` extensions so MCP and the in-app agent get them together:

- `search_media` (existing) gains semantic ranking through the Gemma store plus a modality filter (frame / clip / audio).
- `find_moments` — natural-language brief to time ranges across the project, returning stable asset ids, frame times, and scores.
- `cluster_footage` — returns cluster membership, centroids' nearest frames, near-duplicate groups, coverage stats.
- `match_audio` — voice lines or referenced audio to footage moments.
- Receipts follow the house tool rules: stable ids, explicit no-ops, warnings, no silent clamping.

## Failure behavior

- Model not installed: search falls back to SigLIP; analysis and agent tools report capability-missing with the install action.
- Download failure: retry state identical to smart search.
- Load/inference failure: surfaced verbatim in settings and tool receipts; indexing marks the asset pending, never silently skips.
- Non-video/missing-audio assets: audio indexing is a no-op recorded as current, not an error.
- Apple Silicon only — the app is arm64-only already; no Intel path needed.

## Testing

- Unit: stub `GemmaEmbedding` protocol drives indexer, store round-trip at dim 768, clip-embed sidecar, clustering math, RRF merge, tool receipts (structured, no-op, error paths).
- Integration: small fixture MOV + WAV indexed with the stub; coordinator ordering (SigLIP then Gemma), cancellation mid-asset leaves no partial store entry.
- Sanity (skipped when model absent): known query/frame pairs produce expected cosine ordering; 8-bit vs BF16 tolerance check.

## Out of scope

- Replacing SigLIP2 anywhere (ShotLibrary vision, shot-size classification stay on it).
- Captioning or any generative labeling of clusters.
- Cloud embedding, sign-in, or the legacy online generation path.
