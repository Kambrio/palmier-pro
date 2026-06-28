# Anomaly-aware path cleaning (Hampel spike rejection)

**Date:** 2026-06-28
**Branch:** `subject-tracking`

## Goal
Remove *occasional transient* hand-bumps from object-tracked stabilization paths so Subject Lock /
Point Track shots are smoother — automatically, no new UI. Steady jitter is already handled by the
denoise + smooth/pin stages; this targets the sudden one-off spikes those stages leave behind.

## Approach (researched, not invented)
A **Hampel identifier** — the standard time-series outlier/anomaly detector ([MATLAB `hampel`](https://www.mathworks.com/help/signal/ref/hampel.html)):
for each sample, compare it to the local **median** and **MAD** (median absolute deviation) over a
small window; if it deviates by more than `nSigma · 1.4826 · MAD`, it's an anomaly → replace it with
the local median. Surgical (only touches outliers), cheap (O(n·window)), and isolated from the
working smoother. Chosen over jerk-capping (acts on all motion, adds lag) and Kalman-with-gating
(full rewrite of a working smoother).

## Components
1. `PathSmoother.hampel(_ xs: [Double], halfWindow: Int = 4, nSigma: Double = 3) -> [Double]`
   - For each `i`, window `[i-halfWindow, i+halfWindow]` (clamped); `med` = window median,
     `mad` = median(|w − med|), `sigma = 1.4826·mad`. If `sigma > 0 && |xs[i] − med| > nSigma·sigma`,
     set output to `med`, else keep `xs[i]`. `mad == 0` (degenerate flat window) → leave as-is.
   - Length-preserving, finite-safe, no-op for `count ≤ 2·halfWindow+1`.
2. In `corrections()`, the existing object-path cleaning block (`denoiseRaw > 0`) runs Hampel on each
   channel (tx, ty, rot, scale) **before** the Gaussian denoise:
   `path → hampel(per channel) → gaussianSmooth(per channel) → smooth/pin → correction`.
   Gated on `denoiseRaw > 0`, i.e. object-tracking engines only. Native camera engines (L1/Smooth/
   vid.stab) are untouched.

## Tests (`PathSmootherTests`)
- A single-frame spike on a steady/noisy background is removed (output ≈ neighbours, not the spike).
- A clean linear ramp and a sustained fast pan are left unchanged (no false positives on real motion).
- `hampel` preserves length and finiteness; no-op on short inputs.
- `corrections(denoiseRaw>0)` on a path with an injected spike yields a smoother stabilized path than
  without rejection (the spike doesn't propagate into the correction).

## Out of scope
- Native-engine spike rejection (could extend later), jerk-capping, Kalman, user-facing controls.
