# Whisper transcription backend (downloadable models)

**Date:** 2026-06-24
**Status:** Approved design — pending implementation plan

## Problem

Palmier's transcription (captions, `get_transcript`, transcript search) runs on
Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber`. That API does not support
some languages — notably **Russian** — so those clips cannot be transcribed or
captioned at all.

Add **Whisper** as an alternative, in-process transcription backend with
**in-app downloadable models**, so unsupported languages work. Apple stays the
default for the languages it handles well; Whisper covers the rest.

## Goals

- Transcribe Russian (and other Apple-unsupported languages) to **word + segment**
  parity with the Apple path, so `get_transcript`, transcript-driven editing, and
  word-accurate captions all keep working.
- **Automatic routing by language:** Apple when it supports the language, Whisper
  otherwise. User can override (Always Apple / Always Whisper).
- **In-app model management:** a few curated Whisper model sizes, each downloadable
  with progress, selectable, deletable, in Settings.
- No behavior change for the existing Apple path or any current consumer.

## Non-goals (YAGNI)

- Arbitrary/custom models, full HuggingFace catalog, quantization picker.
- Per-project engine settings.
- Whisper translation mode.
- Whisper-side profanity filtering (Apple's `.etiquetteReplacements` has no Whisper
  equivalent; it is a no-op for Whisper-transcribed media).
- Batch re-transcription of existing media when the engine/model changes.

## Architecture

The seam is the existing value type `TranscriptionResult { text, language, words[],
segments[] }`. Every consumer (`TranscriptCache`, `add_captions`, `get_transcript`,
`EditorViewModel+Captions`, transcript search) already depends only on it, so the
backend becomes pluggable without touching them.

### Backend protocol (`Transcription/Backends/`)

```swift
protocol TranscriptionBackend: Sendable {
    func transcribe(fileURL: URL, language: Locale?, censorProfanity: Bool) async throws -> TranscriptionResult
    func supportedLanguages() -> Set<String>   // BCP-47 language codes
}
```

- **`AppleSpeechBackend`** — the current `Transcription` logic moved behind the
  protocol verbatim (`SpeechTranscriber`/`SpeechAnalyzer`, asset install). No
  behavior change.
- **`WhisperBackend`** — WhisperKit-driven; transcribes via the active model and maps
  output to `TranscriptionResult`. Throws `.whisperModelNotInstalled` if no model is
  downloaded when it is needed.

### Router

The existing `Transcription` enum keeps its exact public static API (`transcribe`,
`transcribeVideoAudio`, `supportedLocales`, `matchLocale`) so nothing downstream
changes. Internally it:

1. Keeps the shared audio-extraction step (`extractAudioTrack` → 16 kHz mono PCM
   `.caf`) and feeds whichever backend — both want the same input.
2. Resolves the target language (explicit pick or Whisper auto-detect, see below).
3. Routes per the decision table below.

A new `Transcription.availableLanguages()` returns Apple's supported locales ∪
Whisper's language set, for the picker.

### Routing decision (pure function, fully testable)

Given requested language and engine mode:

```
mode == .alwaysApple    → Apple   (throws unsupportedLocale if it can't, as today)
mode == .alwaysWhisper  → Whisper (throws whisperModelNotInstalled if none downloaded)
mode == .automatic:
    language known:
        Apple.supports(language)  → Apple
        else                      → Whisper (throws whisperModelNotInstalled if none downloaded)
    language == auto-detect:
        run Whisper language detection on extracted audio (short head window, ~first 30s)
        then apply the "language known" rule
```

Auto-detect runs only when the user picks Auto, on the already-extracted PCM, so the
common explicit-language case pays nothing. If no Whisper model is downloaded,
Auto-detect falls back to Apple behavior and surfaces the download prompt for
unsupported audio rather than failing silently.

## WhisperKit integration & model management

Dependency: [argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) (SPM),
CoreML Whisper on the Neural Engine/GPU. Provides model download from HuggingFace,
word + segment timestamps (DTW), and language detection.

### Curated model catalog (`WhisperModelCatalog`)

| Tier   | Repo                            | ~Disk   | Notes                       |
|--------|---------------------------------|---------|-----------------------------|
| Small  | `openai_whisper-small`          | ~0.5 GB | fast                        |
| Medium | `openai_whisper-medium`         | ~1.5 GB | balanced                    |
| Turbo  | `openai_whisper-large-v3-turbo` | ~1.5 GB | best quality, default       |

All multilingual (Russian-capable). Each entry: id, display name, repo name, approx
size, language coverage. Repo revisions are pinned.

### `WhisperModelManager` (`@MainActor @Observable`, app-level singleton)

- **Per-model state:** `notDownloaded → downloading(progress) → downloaded → error`.
  Downloaded state derived from disk presence on launch (no flag drift).
- **Download:** WhisperKit model-download API into
  `~/Library/Application Support/PalmierPro/WhisperModels/<repo>/`, progress streamed
  to UI. Verify completeness before marking downloaded (no silent partial models).
- **Active model:** one selected model id, persisted in `UserDefaults`
  (`WhisperPreferences`, mirroring `ModelPreferences`/`GenerationProvider.selected`).
- **Engine mode override** (Automatic / Always Apple / Always Whisper): persisted.
- **Delete:** remove a downloaded model to reclaim disk.
- **Lazy load:** the `WhisperKit` instance for the active model is instantiated on
  first transcription and cached; switching active model tears down and rebuilds it.

## Settings UI — `TranscriptionPane`

New pane alongside `ModelsPane`/`AgentPane`, reusing existing list/row/toggle
vocabulary and `AppTheme` styling. Top to bottom:

1. **Engine mode** — segmented/radio bound to the persisted override: Automatic
   (default), Always Apple, Always Whisper.
2. **Whisper models** — list of the three curated tiers. Each row: name, size,
   quality/speed hint, and a trailing control reflecting state — **Download** →
   inline **progress + Cancel** → **radio/checkmark** (select active) with a
   **Delete** (trash). Exactly one downloaded model is active (radio semantics).
3. **Footer** — total disk used by downloaded models; one line explaining Automatic
   routing.

Wording follows the app's HIG-terse voice (action verbs, state names; no chatter).

## Language picker

`CaptionTab` (and the agent locale arg) source from `Transcription.availableLanguages()`
(Apple ∪ Whisper) instead of Apple-only. Whisper-only entries (e.g. Russian) carry a
subtle "Whisper" tag. A new **Auto-detect** option sits at the top.

## Data mapping (WhisperKit → `TranscriptionResult`)

- `segments[]` ← WhisperKit segments (text trimmed, start/end seconds).
- `words[]` ← flattened DTW word timings (`TranscriptionWord{text,start,end}`),
  monotonic, whitespace-trimmed — mirrors the Apple decoder's invariants.
- `language` ← resolved/detected BCP-47 code.
- `text` ← concatenated segment text.
- Existing `offsetting(by:)` (windowed/range requests) works unchanged.

## Caching

`TranscriptCache` key becomes `fileIdentity + backendId + modelId`, so switching
engine or model never returns a stale cross-engine transcript; re-running re-keys.
Memory cap (4) and disk behavior otherwise unchanged.

## Error handling

Extend `TranscriptionError`:

- `.whisperModelNotInstalled` → "No Whisper model downloaded — add one in
  Settings › Transcription."
- `.whisperLoadFailed(reason)` / `.whisperTranscribeFailed(reason)` → surfaced like
  the existing `.analysisFailed`.
- Download failures live in `WhisperModelManager` per-model `.error`, shown inline.

All logged through `Log.transcription` with existing telemetry events, plus
engine/model in the payload.

## Testing

- **Unit (highest value):** router decision table (mode × language-supported ×
  model-present) as a pure function, mocked via `TranscriptionBackend`; cache-key
  composition; `availableLanguages()` union/dedup; `WhisperModelCatalog` integrity;
  output mapping from a fixture WhisperKit result → `TranscriptionResult`
  (monotonic / non-empty / trimmed word + segment invariants).
- The router is pure and backend-agnostic, so decision logic is tested without
  downloading models or running CoreML.
- **Manual/integration:** download Turbo, transcribe a Russian clip end-to-end,
  verify captions + `get_transcript` produce word-accurate Russian.

## Risks

- **HuggingFace availability** — downloads depend on it; pin revisions, surface clear
  errors, verify before marking downloaded.
- **Dependency weight / first-run CoreML compile** — WhisperKit + CoreML assets add
  size and a one-time per-model compile; communicated via download/load UI state.
- **Word-timestamp precision** — Whisper DTW word timings are slightly less precise
  than Apple's; acceptable for the target use case (languages Apple can't do at all).
