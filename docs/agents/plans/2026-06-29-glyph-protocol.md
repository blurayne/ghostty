# Plan: Glyph Protocol — Rendering Integration
Date: 2026-06-29
Priority: P2
Status: **ready to implement** — user decisions recorded 2026-06-29:
Q1=`system=false`, Q2=copy, Q3=coarse.

## Scope Clarification

### Which Protocol

This plan covers the **Glyph Protocol**, a fork-custom APC-based protocol
originating from the Rio terminal project and adapted for this Ghostty fork. It
is distinct from the Kitty graphics protocol unicode-placeholder feature
(`graphics_unicode.zig`), which lets multi-cell images overlap terminal text via
the `U+10EEEE` placeholder codepoint.

The Glyph Protocol lets a running application supply **TrueType simple-glyph
outline data** (and eventually COLR v0/v1 data) for a Private Use Area codepoint.
The terminal renders that outline in place of whatever the system font would draw
for that codepoint, or in place of tofu if no system font covers it. The main use
case is Powerline / Nerd Font / icon fonts without requiring the user to install
patched fonts.

**Specification source of truth:**
`https://github.com/raphamorim/rio/blob/main/specs/glyph-protocol.md`
(local summary: `src/terminal/apc/glyph.zig` top-level doc comment)

**Wire framing:**

```
ESC _ 25a1 ; <verb> [ ; key=value ]* [ ; <payload> ] ESC \
```

Four verbs: `s` (support query), `q` (codepoint query), `r` (register),
`c` (clear).

### What Is Already Implemented

The APC framing, parsing, execution, and storage layers are fully done:

| Layer | Status | Files |
|---|---|---|
| APC handler & dispatch | Done | `src/terminal/apc.zig` |
| Protocol parser | Done | `src/terminal/apc/glyph/request.zig` |
| Protocol responses | Done | `src/terminal/apc/glyph/response.zig` |
| Execute (register/clear/query/support) | Done | `src/terminal/apc/glyph/execute.zig` |
| Glossary (codepoint → outline storage) | Done | `src/terminal/apc/glyph/Glossary.zig` |
| `glyph_rasterize.zig` (outline → bitmap) | Done | `src/font/glyf_rasterize.zig` |
| Terminal dirty flag (`flags.dirty.glyph_glossary`) | Done | `src/terminal/Terminal.zig` |
| Stream handler APC dispatch | Done | `src/termio/stream_handler.zig` |
| System font coverage in `q` response | Partial — executor populates `glossary` bit only; `system` bit needs renderer help |

What is **missing** is the rendering integration: when the renderer draws a cell
whose codepoint is registered in the per-terminal `Glossary`, it currently falls
through to the normal font shaper path and renders whatever the system font
provides (or tofu). The outline stored in the `Glossary.Entry` is never consulted
during rendering.

### What Is Out of Scope for This Plan

- COLR v0 / v1 format support (the executor already rejects them with
  `error.UnsupportedFormat`; the plan acknowledges this as a future extension).
- Animation (the glossary is static per-registration).
- Multi-cell composite glyphs (each codepoint maps to exactly one 1- or 2-cell
  slot as declared by `width`).
- Wide-character / BiDi reordering interactions beyond the `width=2` cell
  reservation already spec-defined.

---

## Architecture Decision: Rendering Path

### Where the Glossary Lives and How the Renderer Sees It

The `Glossary` is owned by `Terminal.glyph_glossary` (one per terminal session,
not per-screen). The renderer holds a `*renderer.State` (wrapped in a mutex) that
contains a `*Terminal`. There are two viable designs for hooking the glossary into
the rendering path:

**Option A — Glossary-as-virtual-font-face (preferred)**

A new `GlossaryFace` struct in the font layer wraps a `*Glossary` reference and
implements the same `renderGlyph` / `glyphIndex` interface that real font faces
expose. The `SharedGrid.renderCodepoint` path already selects fonts from a
`Collection`; we can add `GlossaryFace` as the highest-priority slot in the
collection so that any PUA codepoint covered by the glossary is rasterized from
the stored outline instead of going to a real font.

Advantages:
- Zero changes to the renderer cell-drawing hotpath — it already calls
  `font_grid.renderCodepoint`.
- The glyph atlas and glyph cache (`SharedGrid`) handle deduplication,
  cell-size invalidation, and atlas eviction automatically.
- Glossary outlines are rasterized lazily (first render of each codepoint) and
  cached like any other glyph.

Disadvantages:
- The `Collection` is managed by `SharedGrid`, which lives in a
  `SharedGridSet`. Injecting a mutable `GlossaryFace` reference into the
  collection requires the glossary to be accessible from the font thread, either
  via a thread-safe snapshot or pointer-with-lock. The current per-session
  glossary is owned by `Terminal`, and the renderer reads terminal state under a
  mutex. We need a way to propagate the updated glossary to the `SharedGrid`
  without holding the terminal mutex during rasterization.

The proposed mechanism: **snapshot on dirty**, analogous to how `terminal_state`
is updated from `state.terminal` inside the critical section. When
`terminal.flags.dirty.glyph_glossary` is true, the renderer (inside the mutex)
copies a reference-counted snapshot of the glossary's entries into a
`GlossarySnapshot` that the `GlossaryFace` holds. The snapshot is an
`AutoArrayHashMap(u21, Glossary.Entry)` copied under the mutex; entries contain
only `Glyf.Outline` slices (no allocator state). After copying, the renderer
clears `dirty.glyph_glossary` and invalidates the cached glyphs for all PUA
codepoints that changed.

**Option B — Intercept in renderer cell loop**

Before the renderer calls `font_grid.renderCodepoint` for a cell, check whether
the codepoint is in the glossary and call `glyf_rasterize.rasterize` directly,
then blit the bitmap into the atlas manually.

Disadvantages:
- Duplicates caching logic already in `SharedGrid`.
- Requires manual atlas management.
- Renderer hotpath grows.

**Decision: Option A.** The virtual-face approach reuses all existing caching
infrastructure and keeps the renderer cell loop clean.

### Glossary Invalidation on Font / Cell-Size Changes

When the user changes their font or the window is resized:
- `SharedGrid` invalidates all cached glyph bitmaps (the atlas is cleared and
  the glyph cache is reset).
- A `GlossaryFace` does not need special handling because its entries are
  vector outlines — the next `renderGlyph` call will re-rasterize at the new
  size.
- The `GlossarySnapshot` held by `GlossaryFace` survives font/size changes
  because the outlines are size-independent; only the bitmap cache is invalidated.

### DPR Changes

`SharedGrid` already propagates DPR changes by invalidating the glyph cache.
`GlossaryFace` produces bitmaps at the DPR-scaled cell size requested by the
rasterizer via `Glyph.RenderOptions.grid_metrics`, so DPR changes are handled
automatically.

### System Font Coverage for the `q` Verb Response

The executor (`glyph/execute.zig`) already populates the `glossary` coverage bit
from the `Glossary`. The `system` coverage bit is left false. The correct place to
fill in `system` is in `stream_handler.zig` after calling `glyphProtocol`, using
`font_grid.renderCodepoint` as a probe (a non-null return means system coverage).
This requires passing a reference to the font grid into the stream handler, which
already has access to it via the state it receives. The plan defers a full solution
to Phase 3 and adds a TODO comment for Phase 4 coverage.

---

## Files to Touch

| File | Change |
|---|---|
| `src/font/GlossaryFace.zig` | **New** — virtual font face backed by a `Glossary` snapshot. Implements `glyphIndex(cp)` and `renderGlyph(alloc, atlas, cp, glyph_index, opts)`. Uses `glyf_rasterize.rasterize` to produce bitmaps. |
| `src/font/main.zig` | Export `GlossaryFace`. |
| `src/font/Collection.zig` | Add a dedicated optional `glossary: ?*GlossaryFace = null` slot (not in the priority list; consulted before it). Add `setGlossaryFace(g: ?*GlossaryFace)` helper. Update `getFace` and `renderCodepoint` paths to probe glossary slot first when the codepoint is in a PUA range. |
| `src/font/SharedGrid.zig` | Add `setGlossaryFace(alloc, face: ?*GlossaryFace) !void`. When called, invalidates cached glyphs for all PUA codepoints currently in the glossary and replaces the face reference in the resolver's collection. |
| `src/renderer/generic.zig` | In `updateFrame` critical section: when `terminal.flags.dirty.glyph_glossary`, snapshot the glossary and call `font_grid.setGlossaryFace`. Clear the dirty flag. |
| `src/termio/stream_handler.zig` | In the `apcEnd` handler's `.glyph` arm: after calling `glyphProtocol`, for `.query` responses update the `system` coverage bit by probing the font grid. |

---

## Phases

### Phase 1 — `GlossaryFace`: virtual font face wrapping a glossary snapshot

**Goal:** A standalone, testable struct that converts `Glossary.Entry` outlines
into atlas-ready bitmaps through the existing `glyf_rasterize` path.

**Files:**
- `src/font/GlossaryFace.zig` (new)
- `src/font/main.zig` (export)

**What it does:**
- Holds an owned `AutoArrayHashMap(u21, Glossary.Entry)` snapshot.
- `glyphIndex(cp: u32) ?u32` — returns `cp` directly for any PUA codepoint
  present in the snapshot, `null` otherwise. (Glyph indices for glossary entries
  are the codepoint itself, since there is no HarfBuzz/freetype font behind them.)
- `renderGlyph(alloc, atlas, cp, glyph_index, opts: Glyph.RenderOptions) !Glyph` —
  looks up the `Entry` for `cp`, calls `glyf_rasterize.rasterize` with the
  entry's `design` metrics and `constraint`, then blits the resulting bitmap into
  `atlas` (grayscale) and returns a `Glyph` struct.
- `updateSnapshot(alloc, glossary: *const Glossary) !void` — replaces the
  snapshot, returning the set of changed codepoints for caller-driven cache
  invalidation.
- `deinit(alloc)` — frees snapshot map (does not free outlines; they are
  reference-counted / cloned as needed).

**Tests:**
- `GlossaryFace.glyphIndex` returns the codepoint for a registered PUA slot and
  null for an unregistered one.
- `GlossaryFace.renderGlyph` produces a non-empty atlas region for a valid glyf
  outline.
- `GlossaryFace.renderGlyph` returns `null` when the codepoint is not registered.

### Phase 2 — `Collection` and `SharedGrid` hook

**Goal:** Teach `Collection` to probe `GlossaryFace` before its normal font
priority list when the codepoint is in a PUA range.

**Files:**
- `src/font/Collection.zig`
- `src/font/SharedGrid.zig`

**What it does:**
- `Collection.glossary_face: ?*GlossaryFace = null` — nullable pointer; not
  part of the priority list; does not affect font metrics or shaping.
- In `Collection.getFace` and `SharedGrid.renderCodepoint`: for codepoints in
  `U+E000–U+F8FF`, `U+F0000–U+FFFFD`, or `U+100000–U+10FFFD`, check
  `glossary_face` first. If it returns a glyph, skip the normal font search.
  If it returns null (not registered), fall through to the normal path.
- `SharedGrid.setGlossaryFace(alloc, face: ?*GlossaryFace) !void` — atomically
  updates the glossary face pointer under `SharedGrid.lock.lock()` and invalidates
  all cached PUA glyphs (iterates the glyph cache and removes any entry whose
  codepoint is in a PUA range or whose codepoint is in the new glossary's
  snapshot).

**Tests:**
- `SharedGrid.renderCodepoint` returns a bitmap from `GlossaryFace` when the
  PUA codepoint is in the snapshot.
- `SharedGrid.renderCodepoint` falls through to normal font for PUA codepoints
  not in the glossary.
- `SharedGrid.setGlossaryFace` invalidates only PUA entries in the cache.

### Phase 3 — Renderer integration: dirty-flag → snapshot update

**Goal:** Wire the `terminal.flags.dirty.glyph_glossary` flag into the renderer
frame loop so that glossary changes take effect on the next frame.

**Files:**
- `src/renderer/generic.zig`

**What it does:**
- Inside the `updateFrame` critical section (after acquiring `state.mutex`), add:

  ```
  if (state.terminal.flags.dirty.glyph_glossary) {
      state.terminal.flags.dirty.glyph_glossary = false;
      // snapshot the glossary and push to font_grid
      const glossary = &state.terminal.glyph_glossary;
      self.font_grid.setGlossaryFace(self.alloc, glossary);
      // force a full redraw so changed PUA cells repaint
      self.terminal_state.dirty = .full;
  }
  ```

- `setGlossaryFace` is called with a pointer to the `Glossary` directly; the
  `GlossaryFace.updateSnapshot` call (which copies the entries) happens inside
  `SharedGrid.setGlossaryFace` under the grid lock, so the terminal mutex is not
  held during the copy.

**Tests:**
- After registering a glyph via `glyphProtocol`, `dirty.glyph_glossary` is true;
  after `updateFrame`, it is cleared and `terminal_state.dirty == .full`.
- After clearing all glyphs, `font_grid.setGlossaryFace` is called and the
  previously cached PUA glyph bitmaps are evicted.

### Phase 4 — System font coverage for `q` responses

**Goal:** Fill in the `system` bit of the `q` response so that applications can
detect whether installing the glyph is actually needed.

**Files:**
- `src/termio/stream_handler.zig`

**What it does:**
- After `self.terminal.glyphProtocol(self.alloc, glyph_req)` returns a `.query`
  response, and if the font grid is accessible from the stream handler, probe:

  ```
  font_grid.renderCodepoint(alloc, cp, .regular, .text, opts) catch null
  ```

  If the result is non-null, set `resp.query.status.system = true`.

- The stream handler does not currently hold a reference to the `SharedGrid`; the
  plan notes this as an **open question** (see below) and defers a full solution
  to a follow-up if the architecture doesn't straightforwardly allow it.

**Tests:**
- `q` response for a codepoint covered by a real font returns `system=true`.
- `q` response for an unregistered PUA codepoint covered by a Nerd Font returns
  `system=true`.

### Phase 5 — Build verification and build-system integration

**Goal:** Confirm the build is clean, all new files are included in the build
graph, and targeted tests pass.

**Files:**
- `build.zig` or the relevant `build/` helper (if `GlossaryFace.zig` needs to be
  explicitly listed in a source file set — check whether the font package uses an
  explicit file list or glob).

**What it does:**
- `zig build test -Dtest-filter=GlossaryFace` and `-Dtest-filter=Glossary`
  pass with no failures.
- `zig build` (with `-Demit-macos-app=false` on non-macOS) completes cleanly.
- Manual smoke test: send a `r` command via `printf`, then write the PUA
  codepoint to the terminal and verify the glyph renders rather than tofu.

---

## Test Approach

### Unit-level: Parser + Glossary + GlossaryFace

Already covered in `src/terminal/apc/glyph/request.zig` and `Glossary.zig`.
Phase 1 adds `GlossaryFace` unit tests; Phase 2 adds `SharedGrid` integration
tests. All runnable with `zig build test -Dtest-filter=<name>`.

### Integration-level: Terminal → Renderer round-trip

Phase 3 adds renderer-level tests using `terminal.Terminal` + a mock
`SharedGrid` (or the real one with a test font). The test:
1. Creates a terminal.
2. Registers a glyph at `U+E000`.
3. Calls `renderer_generic.updateFrame` (via the generic test harness used
   elsewhere in `renderer/generic.zig`).
4. Asserts that `font_grid.renderCodepoint(alloc, 0xE000, ...)` now returns
   a non-null bitmap sourced from the `GlossaryFace`.

### Cell-snapping and placement-overlay interactions

Glossary glyphs are drawn as normal text glyphs through the existing cell-glyph
machinery — they inherit the same cell-snapping, cursor overlay, and selection
highlight behavior as any other character. No special handling is needed. Tests
confirm that rendering a PUA cell alongside adjacent regular cells produces the
same geometry as rendering a regular glyph.

---

## Edge Cases

| Edge case | Handling |
|---|---|
| **Font change** | `SharedGrid` invalidates its glyph cache on font change; `GlossaryFace` outlines are vector-only and re-rasterize at the new metrics on next access. |
| **DPR change** | Same as font change — glyph cache is invalidated; `GlossaryFace` re-rasterizes at the new DPR-scaled cell size. |
| **Cell size change (resize)** | Identical to font/DPR — the rasterizer always renders at the requested cell size from `grid_metrics`. |
| **Scrollback eviction** | The `Glossary` lives on the `Terminal`, not the scrollback. Scrolled-off rows that contained PUA codepoints may re-display from scrollback using the current glossary at render time (the codepoint is preserved in the page cell). If the glossary entry was cleared after scrollback, the codepoint renders as tofu — consistent with the spec. |
| **Image-cache pressure** | Glossary bitmaps enter the grayscale `Atlas` alongside normal glyphs. Atlas eviction is not currently implemented (Ghostty grows the atlas as needed). If atlas memory becomes a concern, the `GlossaryFace` path is no different from a fallback font glyph. |
| **Conflicting glyph IDs** | A `r` command on an already-registered PUA codepoint overwrites the previous entry (spec-defined FIFO eviction). `GlossaryFace.updateSnapshot` picks up the new entry, and `SharedGrid.setGlossaryFace` invalidates the cached bitmap for that slot so the new outline is rasterized on next render. |
| **RTL / wide cells** | The `width` option on the `r` command declares the cell width (1 or 2). The renderer already handles wide cells; the `GlossaryFace.renderGlyph` call passes `cell_width` from `Glyph.RenderOptions` so the rasterizer sizes the bitmap correctly. |
| **PUA codepoint also covered by a system font** | `GlossaryFace` takes priority over system fonts for PUA codepoints that are registered. The system font is still used for PUA codepoints that are not in the glossary. The `q` response reports both `system` and `glossary` bits when both apply. |
| **Glossary full (1024 entries)** | FIFO eviction is already implemented in `Glossary.register`. The evicted entry's bitmap is invalidated when `GlossaryFace.updateSnapshot` is called with the next dirty flush. |
| **Empty glyf outline (zero contours)** | `glyf_rasterize.rasterize` on an empty outline returns an all-zero bitmap. The resulting glyph renders as blank (invisible), not tofu. This is correct: the app is deliberately registering a blank glyph (e.g. to suppress tofu without drawing anything). |
| **Very large outline** | The spec caps decoded payload at 64 KiB (enforced in `request.zig`). A 64 KiB glyf record with many contours could produce rasterization that is slow but bounded. No additional limit is needed. |

---

## Out of Scope

- **COLR v0 / v1 formats** — The protocol parser already accepts `fmt=colrv0`
  and `fmt=colrv1` in the wire, and the support-query response could advertise
  them, but `Glossary.Entry.init` returns `error.UnsupportedFormat` for them.
  Implementing color-glyph rasterization (via a color atlas path) is a separate
  effort.
- **Glyph animation** — Not in the Glyph Protocol spec.
- **Non-PUA codepoints** — The spec and executor both reject registrations
  outside the three Unicode PUA ranges. The renderer path only checks the
  `GlossaryFace` for PUA codepoints.
- **libghostty-vt WASM build** — The `glyf_rasterize` module depends on `z2d`,
  which builds for WASM. The `GlossaryFace` should compile for WASM but visual
  correctness in that environment is out of scope.
- **`c` (libghostty C API) exposure** — The glyph protocol is already handled
  through the APC stream; a new C API surface is not needed.

---

## Open Questions

1. **Font grid access in stream handler for system-coverage `q` responses.**
   `stream_handler.zig` currently does not hold a `*font.SharedGrid` reference.
   One option: pass the grid through `renderer.State` and make it readable from
   the IO thread under the existing mutex. Another: add a font-lookup function
   to `app.zig`/`Surface.zig` and call it via the mailbox. The simplest short-term
   answer is to skip the `system` bit and always return `system=false`, deferring
   accuracy to Phase 4. **User decision needed: is Phase 4 required for the initial
   implementation, or can `system=false` be shipped temporarily?**

2. **Snapshot copy vs. shared pointer.**
   The current plan copies the `Glossary.Entry` map into `GlossaryFace` under the
   terminal mutex, then releases the mutex before rasterizing. This is safe but
   copies all entry metadata on every dirty flush (up to 1024 entries). An
   alternative: an `AtomicRcPtr` wrapping the whole `Glossary` map, swapped
   atomically on each `r`/`c`. **Is the copy approach acceptable, or is a
   lower-overhead snapshot mechanism preferred?**

3. **Glyph cache invalidation granularity.**
   When a single `r` command registers one codepoint, `setGlossaryFace` currently
   invalidates *all* cached PUA bitmaps to keep the logic simple. A finer approach
   would invalidate only the specific codepoint. **Is the coarser invalidation
   acceptable for a first implementation?**

4. **`glyf_rasterize.rasterize` thread safety.**
   `rasterize` is a pure function with no shared mutable state. Multiple renderer
   threads can call it concurrently. But `SharedGrid` holds a `lock`; confirm that
   inserting into the atlas is done under the write lock (it is in the existing
   `renderGlyph` path). **No user decision needed; noting for implementer awareness.**

---

## References

### Protocol Specification

- Glyph Protocol spec: `https://github.com/raphamorim/rio/blob/main/specs/glyph-protocol.md`
- Local spec summary: `src/terminal/apc/glyph.zig` (top-level doc comment)
- Local AGENTS guide: `src/terminal/apc/glyph/AGENTS.md`

### Related Ghostty Source Paths

- APC handler: `src/terminal/apc.zig`
- Protocol parser: `src/terminal/apc/glyph/request.zig`
- Protocol responses: `src/terminal/apc/glyph/response.zig`
- Executor: `src/terminal/apc/glyph/execute.zig`
- Glossary: `src/terminal/apc/glyph/Glossary.zig`
- Terminal integration: `src/terminal/Terminal.zig` — `glyphProtocol()`,
  `flags.dirty.glyph_glossary`, `glyph_glossary` field
- Stream handler APC dispatch: `src/termio/stream_handler.zig` — `apcEnd()`
- Outline rasterizer: `src/font/glyf_rasterize.zig`
- TrueType glyf parser: `src/font/opentype/glyf.zig`
- Glyph struct (atlas coords, render options, design metrics, constraint):
  `src/font/Glyph.zig`
- Font face interface: `src/font/face.zig`, `src/font/face/freetype.zig`
- Font collection: `src/font/Collection.zig`
- Shared glyph grid (atlas + glyph cache): `src/font/SharedGrid.zig`
- Generic renderer: `src/renderer/generic.zig`

### Structural Reference Plans

- `docs/agents/plans/2026-06-28-sixel-support.md` — decode-to-pipeline bridge pattern

---

## Open Questions — Explanations and Recommended Answers

Each open question is restated with plain-English context, the tradeoff, and a
recommendation. Fill in the **Decision:** line for each before implementation.

### Q1. Should `q` responses include accurate `system=true|false`?

**What the protocol does.** A remote app can send `q U+E0A0` meaning "do you
already have a glyph for this codepoint?" The reply includes a `system` flag:
`true` means "yes, the system font already covers it — you don't need to
register one"; `false` means "no, please register your version". Apps use the
flag to skip needless registrations and save bandwidth.

**Why it's a question.** To answer truthfully, the OSC parser (which runs on
the IO thread) has to ask the font collection (which lives on the renderer
side) "does any installed font have this codepoint?" That cross-thread plumbing
is non-trivial — either pass a `SharedGrid` pointer through `renderer.State`
under the existing mutex, or round-trip through the apprt mailbox.

**Tradeoff.**
- *Always return `system=false`*: trivial. Apps always send their data. The
  glyph still renders correctly (the registered glyph just gets used). Cost is
  bandwidth waste on glyphs the system would have rendered anyway.
- *Plumb font-grid access*: bandwidth-correct but requires renderer ↔ IO
  thread coupling we don't have today.

**Recommended.** Ship `system=false`. It's never wrong, just suboptimal. Add
real coverage detection later if a concrete use case demands it.

**Decision:** ship `system=false` always. Defer font-grid plumbing to a
follow-up if bandwidth becomes a real concern.

### Q2. Snapshot the glossary by copy, or by atomic refcounted pointer swap?

**What the renderer needs.** The Glossary holds up to 1024 registered glyph
entries. The IO thread mutates it (`r` registers, `c` clears). The renderer
thread reads it to rasterize cells. We need a way for the renderer to read a
consistent view without blocking the IO thread.

**Two approaches.**
- *Copy under mutex*: when the dirty flag fires, the renderer briefly locks
  the mutex, memcpy's the entry table into a per-frame `GlossaryFace`,
  unlocks, then rasterizes from the copy. Simple. Cost per flush: ~32–64 KB
  of *metadata* copying. The outline byte arrays are arena-allocated and
  referenced by slice — not copied.
- *Atomic refcounted pointer swap*: writers build a new map, atomically swap
  the pointer; readers atomically load + bump refcount. Zero copy. But
  lifetime management gets tricky, and the renderer's bitmap cache still
  references old entries by codepoint, complicating invalidation.

**Recommended.** Copy. 32–64 KB per glossary change is nothing on modern
hardware. Lock-free RC is over-engineering for the data volume.

**Decision:** copy under the terminal mutex into a per-frame
`GlossaryFace`. No atomic-RC pointer machinery.

### Q3. Coarse (whole-PUA) or fine (per-codepoint) bitmap cache invalidation on `r`?

**What's cached.** The renderer caches *rasterized bitmaps* keyed by codepoint.
When `r U+E000` re-registers an outline, the previously cached bitmap for
U+E000 is stale and must be evicted.

**Two approaches.**
- *Coarse*: one call invalidates all cached PUA bitmaps (U+E000–U+F8FF and
  supplementary planes). Trivial to implement. Side effect: evicts hundreds
  of unrelated PUA glyphs that will re-rasterize on next draw.
- *Fine*: surgical eviction of only the affected codepoint. Requires plumbing
  an `evict(codepoint)` API into the glyph cache.

**Real-world pattern.** Most apps register all their glyphs in a startup burst,
then start rendering. Under that pattern coarse ≡ fine — there's one big
re-rasterize after the burst either way. The pathological case is an app that
interleaves registrations with rendering (register → render → register →
render); coarse causes a stutter on each registration.

**Recommended.** Coarse. Matches the dominant usage pattern. Upgrade to fine
only if real apps cause stutter.

**Decision:** coarse — invalidate the whole PUA bitmap cache on any `r`
or `c`. Upgrade to per-codepoint only if a real app demonstrates stutter.

---

## Pre-implementation checklist

Before an implementation agent picks this plan up, confirm:

- [x] Q1 has a recorded **Decision:** — `system=false`
- [x] Q2 has a recorded **Decision:** — copy
- [x] Q3 has a recorded **Decision:** — coarse
- [x] User has acknowledged that this is a fork-custom protocol with no upstream
      acceptance path (we never merge to ghostty-org)
