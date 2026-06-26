# Stabilization Quality: L1 Native Smoother + vid.stab Engine

**Date:** 2026-06-26
**Status:** Approved (user chose "both")

## Problem

The current stabilizer uses a **Gaussian low-pass** smoother. On IBIS footage (Fuji X-S20)
the micro-jitter is already gone; the residual is **walking-cycle bob (~2 Hz) and slow
hand drift** — low/mid frequency. A Gaussian only *attenuates*; it can't produce a
genuinely smooth, cinematic path. Result: "works but not smooth."

## Two engines (user-selectable, mirrors ChatBackend/GenerationProvider pattern)

### Engine A — Native L1-optimal (default, this phase)
Replace the Gaussian smoother in `PathSmoother` with **L1 trend filtering** per channel
(tx, ty, rot, scale) — the tractable core of Grundmann's L1-optimal camera paths. It
produces a path made of near-constant / linear segments (mimics a pro operator: locked,
smooth pan, smooth accel), which removes walking bob while preserving the intended
tracking move.

- Per channel, minimize: `λ_data · Σ|p_i − x_i|  +  λ_smooth · Σ|p_{i-1} − 2p_i + p_{i+1}|`
  (L1 data term = robust to registration outliers; L1 second-difference = piecewise-linear).
- Solve via **IRLS** (iteratively reweighted least squares): each iteration is a banded
  SPD linear system solved with a simple iterative solver (CG / Gauss-Seidel, ~few hundred
  iters; the system is well-conditioned). 6–10 IRLS rounds converge.
- `smoothness` (0…1) maps to `λ_smooth` (higher = flatter/smoother path).
- Everything else (correction = smoothed − raw, NaN-safe clamps, crop zoom) is unchanged.
- Stays in the existing non-destructive per-frame transform pipeline; no new media.

This is the change that actually fixes the footage. Self-contained to `PathSmoother`.

### Engine B — vid.stab (FFmpeg CLI, phase 2)
Shell out via the existing `CLILocator` / `CLIProcess` (same pattern as the Higgsfield /
Claude CLIs — locate, don't bundle; license is fine for a personal project).

- Two-pass on the clip's **source**:
  1. `ffmpeg -i SRC -vf vidstabdetect=shakiness=…:result=TRF -f null -`
  2. `ffmpeg -i SRC -vf vidstabtransform=input=TRF:smoothing=…:crop=black,unsharp=… OUT.mov`
- Produces a **baked stabilized media file** stored like a derived asset (under
  `media/stabilized/<assetId>.mov`, keyed by source signature like proxies).
- When a clip uses the vid.stab engine, the renderer resolves to that file (a new
  resolution path alongside proxy), so vid.stab is applied destructively-but-cached.
- Background job + HUD, mirroring proxy generation. Requires `ffmpeg` built with
  `--enable-libvidstab` on PATH; if absent, the engine is disabled with a clear message.

## UI

Reframe the inspector picker from motion-model (Position/Similarity/Perspective —
currently all collapse to one path) to **Engine: Native (L1) | vid.stab**. Keep the
smoothness slider (drives `λ_smooth` for native, `smoothing` for vid.stab) and crop-to-fit.
If ffmpeg+vidstab isn't found, the vid.stab option shows as unavailable.

## Plan / phasing

1. **Phase 1 (now):** Engine A — L1 trend-filter smoother in `PathSmoother`, behind the
   existing pipeline. Verify with the jitter-reduction test + on the user's real clip.
2. **Phase 2:** Engine B — vid.stab CLI provider, baked-media resolution, engine picker.

## Testing
- L1: extend `applyingCorrectionReducesJitter` — on a ramp+bob synthetic path, assert the
  smoothed path's second-difference energy drops far more than Gaussian did, and the
  intended ramp (the tracking move) is preserved (low-freq trend retained).
- vid.stab: locate-or-skip test; integration test gated on ffmpeg availability.
