# Proxy Media — Design

Date: 2026-06-25
Status: Draft for review
Branch (intended): `proxy-media`

## Goal

Let users edit heavy / high-resolution (6K) footage smoothly by editing against
low-resolution **proxy** copies, while **export always uses the original source**.
This attacks the *decode* cost that the preview render-size cap (already shipped)
cannot: a 6K long-GOP HEVC frame is expensive to decode/scrub; a small intra-frame
ProRes proxy is not.

This is the durable companion to the shipped Adaptive preview render cap, which only
reduces *compositing* cost.

## Decisions (settled)

- **Format:** Apple ProRes 422 Proxy (`AVVideoCodecType.proRes422Proxy`) — intra-frame,
  fast random decode.
- **Resolution:** user-selectable dropdown by short side — **240p / 360p / 480p /
  720p (default) / 1080p** — aspect preserved, even dimensions.
- **Generation:** on-demand ("Create Proxies"), background, with progress + cancel.
- **Toggle:** one global per-project switch ("Use Proxies").
- **Scope (v1):** proxy only (no full-res "optimized" media); video only (audio
  passthrough; images/Lottie/text need no proxy).

## Non-goals (v1, YAGNI)

- Per-asset proxy/source override (global toggle only).
- Auto-generate on import.
- "Optimized" (full-res ProRes) media.
- Cloud/remote proxies.

## Architecture

Five units, each independently understandable:

### 1. Model & persistence
- `ProxyResolution` enum: `p240, p360, p480, p720, p1080` → `shortSide: Int`; `label`.
- `MediaManifest` (media.json) gains:
  - `useProxies: Bool = false` — the global project toggle.
  - `proxyResolution: ProxyResolution = .p720`.
- `MediaManifestEntry` gains `proxyPath: String?` — relative path inside the package
  once a proxy is ready (nil = none). Proxy readiness = file exists at `proxyPath`.
- Package layout: proxies live at `media/proxies/<assetId>.mov` (new convention under
  the existing `Project.media` dir; add `Project.proxies` to `Utilities/Constants.swift`).
- In-memory per-asset status on `MediaAsset`: `proxyStatus: .none/.generating/.ready/.failed`
  (drives media-panel badges + the generation HUD; not persisted — derived on open from
  `proxyPath` + file existence).

### 2. ProxyService (new `Sources/PalmierPro/Proxy/`)
- `transcode(asset:resolution:) async throws -> URL` — `AVAssetReader` → `AVAssetWriter`
  with `.proRes422Proxy`, video scaled to the target short side (aspect-preserving, even
  dims, never upscaled past source), audio passthrough. Reports fractional progress;
  cancellable.
- `ProxyJobQueue` (@MainActor coordinator): "Create Proxies" enqueues all video assets
  lacking a current proxy; runs with a small concurrency cap (reuse the `AsyncSemaphore`
  pattern from `MediaVisualCache`); updates `MediaAsset.proxyStatus`; writes `proxyPath`
  into the manifest on success.
- **Invalidation:** store source identity (mtime+size, mirroring `TranscriptCache.key`)
  alongside the proxy; a proxy whose source changed (relink/replace) is treated as stale
  → regenerate. Deleting/replacing an asset removes its proxy file.

### 3. Resolve path (the swap)
- `MediaResolver.resolveURL(for:)` stays source-only. Add
  `resolveURL(for:preferProxy:)` (or a thin `previewResolveURL`) that returns the proxy
  URL **only when** `useProxies` is on AND a current proxy exists; otherwise source.
- `VideoEngine.rebuild()` builds its composition with the **proxy-aware** resolver.
- `ExportService` / `TimelineRenderer` keep the **source-only** resolver. Export quality
  is never affected by the proxy toggle.
- Toggling `useProxies` (or changing resolution) triggers `videoEngine.rebuild()` so the
  preview swaps live.

### 4. Effect-radius correctness (the real gotcha)
Effects render in **source-pixel space** (`FrameRenderer.swift:73`), so absolute-pixel
params (Gaussian blur, glow, motion blur — `EffectParamSpec.unit == "px"`) would look
proportionally *stronger* on a smaller proxy than on the full-res export.

Fix: when a layer is rendered from a proxy, scale px-unit effect params **down** by the
proxy's shrink factor so the blur covers the same *fraction* of the frame. A radius `R`
on a source of long side `L_s` is the fraction `R/L_s`; on a proxy of long side `L_p`
(`< L_s`) the matching radius is `R · (L_p / L_s)`. Plumbing:
- `LayerPlan` already carries `natSize` (the decoded frame size = proxy size when proxied).
- Carry a per-layer `proxyScale = proxyLong / sourceLong` (≤ 1; **1.0 when not proxied**),
  derived from `MediaAsset.sourceWidth/Height` vs the proxy's natural size.
- `EffectRegistry.descriptor.render(...)` multiplies params whose `unit == "px"` by
  `proxyScale`. Ratio-based effects (color, transform, crop fractions) are untouched —
  already resolution-independent.
This keeps preview WYSIWYG with export.

### 5. Analysis reads source, not proxy
Pixel-analysis must sample the **source** for accuracy regardless of the toggle:
- Color scopes/histogram (`ColorScopes`), chroma-key color pick, auto-color, SigLIP visual
  search, asset thumbnails. These resolve via the source-only path.

## UI

- **Preview bar:** a "Proxies" menu next to the new Preview-Quality menu (Timeline tab):
  - `Use Proxies` (checkbox toggle).
  - `Proxy Resolution ▸` submenu: 240p / 360p / 480p / 720p / 1080p (checkmark on active).
  - `Create Proxies` — enqueues generation for assets missing a current proxy.
  - Shows count / "All proxies ready" state.
- **Generation progress:** a HUD mirroring `MediaLoadHUD`/`CaptionProgressHUD`
  ("Creating proxies — N of M"), bottom corner, cancellable.
- **Media panel:** small per-asset proxy badge (ready / generating / none). Optional in v1.
- **Voice:** action-led, terse — "Create Proxies", "Use Proxies", "Proxy Resolution".

## Data flow

```
Create Proxies ─▶ ProxyJobQueue ─▶ ProxyService.transcode (bg, gated)
                                     └▶ media/proxies/<id>.mov + manifest.proxyPath
                                        + MediaAsset.proxyStatus=.ready

Use Proxies ON ─▶ VideoEngine.rebuild ─▶ proxy-aware resolveURL
                                          ├ proxy exists → proxy URL (light decode)
                                          └ else          → source URL (fallback)
                 FrameRenderer: px-unit effect params × proxyScale

Export ─────────▶ source-only resolveURL (always full quality)
```

## Error handling / edge cases

- Proxy missing while toggle on → silently fall back to source for that asset (no break).
- Transcode failure → `proxyStatus=.failed`, surfaced in HUD/badge; asset uses source.
- Source relinked/replaced/edited → proxy stale → regenerate; never serve a mismatched proxy.
- Project moved/copied → proxies travel inside the package (relative paths).
- Changing proxy resolution → existing proxies become stale → prompt/queue regeneration.
- Disk pressure → proxies are deletable; "Delete Proxies" command (stretch) frees space.

## Testing

- `ProxyService`: transcode a fixture clip → output is ProRes 422 Proxy at expected
  short-side, aspect preserved, even dims, not upscaled. (Rendering test, like existing
  `Export` suites.)
- Resolve path: with `useProxies` on + a ready proxy, preview resolver returns proxy;
  export resolver returns source; missing proxy falls back to source.
- Effect scaling: a px-unit effect (blur radius R) on a proxy of scale k produces the same
  visual extent as radius R on source — assert scaled param `R*k_inv` feeds the filter.
  (Extend `Rendering`/compositor tests.)
- Invalidation: changed source identity marks proxy stale.

## Rollout / sequencing

1. Model + manifest fields + `Project.proxies` constant.
2. `ProxyService` transcode + a unit test.
3. `ProxyJobQueue` + status + HUD.
4. Proxy-aware resolve path in `MediaResolver` + wire `VideoEngine` (export untouched).
5. Effect px-param scaling in `FrameRenderer`/`EffectRegistry`.
6. UI menu (toggle, resolution submenu, Create Proxies) + media-panel badge.
7. Invalidation on relink/replace/resolution-change.

Each step is independently testable; 1–4 deliver the core perf win, 5 guarantees WYSIWYG,
6–7 complete the UX.
