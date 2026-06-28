# OmniVoice: local on-device voice generation

**Date:** 2026-06-28
**Status:** Draft (design) — awaiting user review

## Goal

Give Palmier its first **local, on-device voice generation** (text-to-speech). Today
every TTS path (`elevenlabs-tts-v3`, `gemini-3.1-flash-tts`) routes through Convex and
requires a Palmier sign-in + credits. There is no offline / no-account / no-API-key
voice option.

Add one: a local provider backed by **OmniVoice** (`k2-fsa/OmniVoice`, target tag
**0.1.5**) that runs on the user's Mac via Apple Silicon MPS — no sign-in, no credits,
no network at generation time. It must expose three capabilities:

1. **Plain multilingual TTS** — text + language → speech (646 languages, default voice).
2. **Voice design** — generate without a reference, steered by `instruct` attributes
   (gender, age, accent, whisper).
3. **Voice cloning** — clone a voice from a short reference audio asset.

## Why not a self-contained compiled model (ONNX / CoreML / MLX)

Investigated and rejected as out of scope (months-long port, not a feature). Evidence
from the OmniVoice source at `~/Documents/OmniVoice`:

- It is a **pipeline of four pieces**, not one model: a **Qwen3-0.6B** LLM backbone
  loaded with **`flex_attention`** (PyTorch 2.5+ only; unsupported by ONNX and CoreML),
  a learned audio-embedding layer, audio logit heads, and the
  **`HiggsAudioV2TokenizerModel`** neural codec (`omnivoice/models/omnivoice.py:268`)
  that decodes tokens → waveform.
- Inference is an **iterative 32-step masked-decoding loop** with per-item dynamic
  `topk`/`scatter` and Gumbel random sampling *inside* the model
  (`omnivoice/models/omnivoice.py:1226-1268`) — not a single static forward pass, so
  `torch.onnx.export` / `jit.trace` cannot capture it without unrolling.
- The hard stop is the **`HiggsAudioV2` codec**: no ONNX/CoreML/MLX weights exist for it
  anywhere and its internals are not in the repo. Without it there is no audio out.

Per-target feasibility: ONNX **Impractical**, CoreML **Hard**, MLX **Hard** (the only
plausible native route, still codec-blocked). Decision: ship the **local Python worker**
path now; a future native port can replace the runtime behind the same provider seam
without changing the editor-facing surface.

## Confirmed decisions

- **Runtime acquisition:** detect-or-provision. Probe a configured path + known
  locations first (reuses an existing `~/Documents/OmniVoice/.venv`); otherwise
  **auto-provision**.
- **Provisioner mechanism:** **uv-managed**. Bundle the static `uv` binary (the only
  thing we sign/notarize); it installs a pinned CPython, creates the venv in
  Application Support, `pip install omnivoice==0.1.5`, then snapshot-downloads HF
  weights with progress.
- **Capabilities:** all three — plain TTS, voice design, voice cloning.
- **Scope of the provider:** **TTS category only.** Music and SFX stay on
  Palmier/Convex. Selecting OmniVoice changes only the TTS route.
- The worker is **bundled** in app `Resources/`, adapted from good-news's
  `omnivoice_worker.py` (stdin JSON job → JSON-line progress → WAV per segment).

## Non-goals

- No native/compiled (ONNX/CoreML/MLX) OmniVoice — see above.
- No change to music/SFX generation, nor to the cloud TTS models.
- No change to the existing cloud download/finalize/timeline-placement path — the local
  provider feeds WAV files into it.
- No new model-catalog backend — the OmniVoice TTS entries are registered locally, not
  fetched from Convex.
- No bundling of Python/PyTorch/weights inside the `.app` (they are provisioned to
  Application Support as user data).

## Architecture overview

A new local-voice seam parallel to the existing `GenerationProvider.higgsfield`
local-CLI backend, plus runtime plumbing modeled on `WhisperModelManager`.

```
generate_audio (TTS) ──▶ GenerationProvider.selected == .omnivoice?
        │                         │ yes
        │ no (palmier/cloud)      ▼
        ▼                 OmniVoiceGenerationProvider
  existing Convex          ├─ builds JSON job (text/lang/instruct/ref_audio/segments)
  submit/poll path         ├─ OmniVoiceRuntime.ensureReady()  ──▶ OmniVoiceProvisioner (uv)
                           ├─ CLIProcess(python omnivoice_worker.py) ⇄ stdin/stdout JSON
                           └─ WAV result ──▶ existing import / finalize / place-on-timeline
```

### Components

Each is one file with one purpose and a small, testable interface.

1. **`OmniVoiceRuntime`** (`Generation/OmniVoice/OmniVoiceRuntime.swift`)
   - `@Observable @MainActor`. State machine:
     `notInstalled | provisioning(Progress) | ready(Resolved) | error(String)`.
   - `Resolved`: `{ pythonURL, workerScriptURL, modelCachePresent: Bool, device: String }`.
   - `resolve()` — probe order: (a) Settings override path, (b) Application Support
     provisioned venv, (c) known dev location `~/Documents/OmniVoice/.venv`. A path is
     "usable" if `python` exists and `import omnivoice` succeeds (cheap `-c` probe).
   - `ensureReady() async throws -> Resolved` — resolve, else kick provisioning.
   - Mirrors `WhisperModelManager`'s read/state shape so the Settings UI is familiar.

2. **`OmniVoiceProvisioner`** (`Generation/OmniVoice/OmniVoiceProvisioner.swift`)
   - Bundled binary: `Resources/bin/uv` (arm64, signed; located via `Bundle.main`).
   - Steps, each emitting progress: `uv python install <pin>` → `uv venv <appsupport>/OmniVoice/.venv`
     → `uv pip install omnivoice==0.1.5` → HF snapshot download of `k2-fsa/OmniVoice`
     (+ the HiggsAudioV2 codec repo) into the venv's HF cache so weights are local.
   - Runs each step via `CLIProcess`; parses stdout for coarse progress.
   - **Quarantine handling:** after provisioning, strip the `com.apple.quarantine`
     xattr from the provisioned tree (`xattr -dr`). The worker runs as a **child
     process** (not dylibs loaded into Palmier), so Palmier's hardened runtime /
     library-validation does not gate it; quarantine on the freshly-written python +
     torch dylibs is the real risk and is cleared here.
   - Target dir: `~/Library/Application Support/PalmierPro/OmniVoice/`.

3. **`omnivoice_worker.py`** (`Sources/PalmierPro/Resources/OmniVoice/omnivoice_worker.py`)
   - Adapted from `good-news/good_news/vendor/omnivoice_worker.py`: read one JSON job
     from stdin, `OmniVoice.from_pretrained(..., device_map=<mps|cpu>)`, build the voice
     clone prompt once when `ref_audio` is present, generate each segment, `torchaudio.save`
     to the requested output path, stream JSON-line progress
     (`model_ready` / `job_start` / per-segment `done|cached|error` / `complete`).
   - `num_step` configurable (default 16 for ~2× speed; 32 = quality).

4. **`OmniVoiceGenerationProvider`** (`Generation/OmniVoice/OmniVoiceGenerationProvider.swift`)
   - `static func generate(job:) async throws -> [String]` (WAV paths), structurally
     analogous to `HiggsfieldGenerationProvider.generate`.
   - Builds the worker JSON from `AudioGenerationParams`; spawns
     `CLIProcess(executable: pythonURL, arguments: [workerScript])`, writes JSON to
     stdin, parses stdout JSON lines into progress + result paths; kills on cancel/timeout.

5. **Provider wiring**
   - `GenerationProvider` gains `.omnivoice` (`Generation/Higgsfield/GenerationProvider.swift`)
     with `displayName "OmniVoice (Local)"`, `canGenerate` = runtime ready (no account),
     and a tailored `cannotGenerateReason` ("not installed — provision in Settings").
   - **TTS-only gate:** because the enum is global, the routing decision in
     `ToolExecutor+Generate.generateAudio` checks *both* `selected == .omnivoice` **and**
     `model.category == .tts`; non-TTS audio falls back to the Palmier path regardless.
   - Settings → Models (`Settings/ModelsPane.swift`): add the OmniVoice option and a
     runtime panel (status, "Provision…" with progress, path override, "Reveal in Finder").

### Data flow & argument mapping

`generate_audio` (`Agent/Tools/ToolExecutor+Generate.swift:242`) → `AudioGenerationParams`
→ worker job:

| tool arg            | worker field        | capability     |
|---------------------|---------------------|----------------|
| `prompt`/text       | `segments[].text`   | all            |
| target `language`   | `language`          | all (646 langs)|
| `styleInstructions` | `instruct`          | voice design   |
| `voice` (ref asset) | `ref_audio`         | voice cloning  |
| (n/a)               | `num_step`          | quality/speed  |

**Voice cloning source:** `voice` resolves to a reference WAV — either an imported
"voice reference" asset or an existing project media/clip used as the reference. A minimal
"voice reference" concept is added so cloning has a concrete file path; absent a
reference, the provider uses plain TTS or `instruct` (voice design).

**Result:** worker writes WAV(s); provider returns the path(s) into the existing
generated-media import/finalize path, including the optional auto-place-on-timeline
behavior already used by cloud audio gen.

## Error handling

- **Runtime not ready** → actionable message via `cannotGenerateReason` + an offer to
  provision; same shape the Higgsfield/Palmier paths already use.
- **Provisioning failure** (network, uv, pip, disk) → `error(reason)` state, retryable,
  with the failing step named.
- **Worker `error` lines** → surfaced per segment; partial successes preserved (worker
  already skips/caches completed outputs).
- **Cancel / timeout** → `CLIProcess` terminates the child; in-flight WAVs discarded.
- **Quarantine kill** (child python killed by Gatekeeper) → detected as launch failure;
  message points at re-provision / xattr clear.

## Testing

Swift unit tests (no model required):
- Worker-job JSON builder from `AudioGenerationParams` (each capability + edge cases).
- JSON-line progress parser (`model_ready`/`job_start`/`done`/`cached`/`error`/`complete`,
  malformed lines).
- `OmniVoiceRuntime` state machine + probe order (override > app-support > dev path).
- Argument→worker mapping table above.

Integration (opt-in, skipped in CI): if a runtime resolves, run the worker end-to-end on
a tiny text and assert a non-empty 24 kHz WAV.

Provisioner is exercised manually (network + multi-GB downloads); its step orchestration
and progress parsing are unit-tested with fake `CLIProcess` output.

## Open risks

1. **Gatekeeper / quarantine** on provisioned python + torch dylibs is the top risk;
   mitigation is the post-provision `xattr -dr` clear + child-process execution. Needs
   verification on a clean machine, not just the dev box.
2. **Download size** (~2 GB torch + ~1.5 GB weights) and first-run time — surfaced via
   progress UI; provisioning is explicit/opt-in, never silent.
3. **uv + torch wheel availability** for the pinned CPython on arm64 macOS — pin a known-
   good combination (existing dev venv uses Python 3.13 + torch 2.8).
4. **OmniVoice 0.1.5 API parity** with the 0.1.2 worker — verify `generate` /
   `create_voice_clone_prompt` signatures before pinning.
