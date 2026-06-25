# Config Editor — Implementation Plan

**Date:** 2026-06-25
**Branch context:** feat/ghostty-tiling
**Author:** Research agent (Claude Sonnet 4.6)

---

## 1. Overview

### Feature Description

An interactive, in-app configuration editor window for Ghostty's GTK apprt. The editor surfaces every known config key with its current value, documentation, type-appropriate input widget, and optional instant-apply and persist-to-disk semantics. It replaces the current "open config in external editor" workflow (which calls `openConfig()` in `application.zig:2422`) with a native UI that is always synchronized with the live config.

### Why It Matters

- Users currently must know config key names by heart or read the man page; the editor gives discoverable, annotated access to all ~200+ config fields.
- The existing "reload config" and "open-config" actions are disconnected; the editor unifies them into one round-trip: see → edit → apply (→ persist).
- The `help_strings.Config` comptime module already contains clean Markdown doc-comments for every field; surfacing them in-app avoids external docs.

### Scope

**In scope:**
- GTK/Linux only (GTK apprt, `src/apprt/gtk/`)
- Read + write of the primary user config file (the path returned by `config/edit.openPath`)
- All scalar config fields (bool, int, float, enum, optional variants, string, packed-struct flags)
- Repeatable fields (e.g. `font-family`, keybinds) — read-only display in P2, full edit in a later phase
- External-change detection via `gio.FileMonitor`

**Out of scope:**
- macOS / Swift apprt — no changes there
- Conditional configs (`config-file` includes, `conditional.zig`) — out of scope for now
- Keybind table editor — complex union type, defer to separate feature
- Per-surface (override) config editing

---

## 2. Discovery Findings

### 2.1 Config Field Metadata

**Source:** `src/config/Config.zig`, `src/config/key.zig`, `src/config/formatter.zig`, `src/config/formatter_file.zig`, `src/helpgen.zig`

Config fields are plain Zig struct fields on the `Config` struct. They follow these patterns:

| Category | Zig type example | Notes |
|---|---|---|
| Bool | `bool`, `?bool` | Optional bools mean "use default" |
| Integer | `u8`, `f32` | font-size is f32 |
| Enum | `CursorStyle`, `FontStyle` | `@typeInfo(T).@"enum"` → iterate `.fields` for allowed values |
| Packed struct (flags) | `FontSyntheticStyle` | Rendered as `flag,no-flag,...` |
| String | `?[:0]const u8` | Nullable |
| Repeatable | `RepeatableString`, `RepeatableFontVariation` | Implement `formatEntry` |
| Custom struct/union | `Keybinds`, `Color`, etc. | Have their own `formatEntry` / `clone` |

**Key enumeration:** `src/config/key.zig` (lines 7–32) generates `Key` as a comptime enum of every non-`_`-prefixed field in `Config`. This is the exact set of user-facing fields.

**Doc-comments:** `src/helpgen.zig` (lines 29–73) parses `Config.zig`'s AST at build time to extract each field's doc-comment block, outputting it as a generated Zig module `help_strings`. The module is available at compile time via `@import("help_strings")`. Access pattern:

```zig
const help = @field(help_strings.Config, field.name); // [:0]const u8 Markdown text
```

Pattern confirmed in `src/config/formatter_file.zig` lines 50–57.

**Formatter:** `src/config/formatter.zig` provides `formatEntry(comptime T, name, value, writer)` which knows how to render every supported type to `key = value\n` form. `FileFormatter` in `formatter_file.zig` wraps this with optional doc-comment headers and a `changed`-only filter.

**Parsing back:** `Config.loadIter` (line 3932) calls `cli.args.parse(Config, alloc, self, iter)`. The `cli.args` system accepts a `LineIterator` over `key = value` lines. A single-field round-trip can be done by constructing a synthetic `LineIterator` over one line.

**Default value:** `Config.default(alloc)` (line 3906) creates a fresh config at default values. The `changed(self, new, key)` method (line 5083) deep-compares a field against another config, which is how we detect modifications.

### 2.2 Terminal Inspector — UX Inspiration

**Files:** `src/apprt/gtk/class/inspector_window.zig`, `src/apprt/gtk/class/inspector_widget.zig`, `src/apprt/gtk/ui/1.5/inspector-window.blp`, `src/apprt/gtk/ui/1.5/inspector-widget.blp`

The inspector follows a clean two-class pattern:

1. **`InspectorWindow`** (`adw.ApplicationWindow`) — the top-level window. Defined as a GObject extern struct with a blueprint template. Has a `surface` property (GObject property, getter/setter via `Private`). Opens via `window.zig:toggleInspector()` → `surface.controlInspector(.toggle)`.

2. **`InspectorWidget`** — the inner ImGui-based rendering widget, bound to the window via `bindTemplateChildPrivate`. The window monitors the widget's `surface` property via `notify::surface` in the blueprint.

**Opening mechanism:** A `win.toggle-inspector` GtkAction (registered in `window.zig:574`) calls `actionToggleInspector` → `toggleInspector()`. No `adw.Dialog` used — it is a full `adw.ApplicationWindow`.

**Key pattern to reuse:**
- `GObjectType` `extern struct` + `Private` inner struct + `Common(Self, Private)` mixin
- `gobject.ext.defineClass` / `gobject.ext.defineProperty` / `gobject.ext.registerProperties`
- Blueprint template loaded from gresource via `gresource.blueprint(.{ .major = 1, .minor = 5, .name = "..." })`
- `bindTemplateChildPrivate` for referencing template-declared child widgets
- `bindTemplateCallback` for blueprint signal handlers

### 2.3 GTK Apprt UI Conventions

From reading `application.zig`, `window.zig`, `command_palette.zig`, and blueprint files:

- **Window type:** New top-level tools use `adw.ApplicationWindow` (inspector) or `adw.Dialog` (command palette, config errors). For the config editor — which is app-level, not surface-attached — an `adw.ApplicationWindow` is the right choice, matching inspector precedent.

- **Action registration:** App-level actions are registered in `Application.startupActions()` (line ~1444) via `ext.actions.add`. The action handler calls application methods directly. A new `"open-config-editor"` action follows this pattern exactly.

- **Property binding:** `gobject.Object.bindProperty(source, prop, target, prop, flags)` is used extensively (e.g. `window.zig:357`, `2233`). The blueprint `bind` keyword handles the GTK side. The `config` property flows: `Application` → `Window` → child widgets via `bindProperty` calls with `.sync_create`.

- **ListView pattern (from command palette):** `command_palette.blp` uses `Gtk.ListView` + `Gio.ListStore` + `Gtk.BuilderListItemFactory` + `Gtk.FilterListModel`. This is the right pattern for the scrollable config key list. The factory's `template Gtk.ListItem` block defines per-row layout.

- **Adw.PreferencesWindow:** Not currently used in the codebase. It would group fields by section but adds complexity for custom per-row edit widgets. **Decision to make** (see Open Questions).

### 2.4 File Watching

**Current state:** There is NO `gio.FileMonitor` usage anywhere in `src/apprt/gtk/`. Config reload is entirely manual — triggered by `app.reload-config` GtkAction or `SIGUSR2` signal (application.zig:1537).

`gio.File` IS available and used in the GTK apprt (surface.zig:1855 for drag-and-drop), so the bindings are already imported.

**Plan:** The editor will call `gio.File.newForPath(path).monitor(flags, cancellable)` after opening the config file path. The returned `*gio.FileMonitor` emits `"changed"` signals. The editor connects to this signal to detect external modifications.

---

## 3. Architecture

### 3.1 Components

```
Application (existing)
  └─ "open-config-editor" action (new)
       └─ ConfigEditorWindow (new, adw.ApplicationWindow)
            ├─ Private.config_path: [:0]const u8   (resolved once at open)
            ├─ Private.live_config: *Config          (clone of current live config)
            ├─ Private.default_config: *Config       (Config.default — for Reset)
            ├─ Private.edits: HashMap(Key, []const u8) (pending key=value strings)
            ├─ Private.file_monitor: *gio.FileMonitor
            ├─ Private.file_mtime: i64
            ├─ Private.instant_reload: bool (checkbox state)
            ├─ Private.persist: bool (checkbox state)
            └─ ConfigEditorWidget (new, gtk.Box or adw.PreferencesGroup)
                  └─ per-row: ConfigEntryRow (custom GObject or direct builder template)
                        ├─ key label (Gtk.Label, monospace)
                        ├─ value editor (type-dispatched widget)
                        ├─ save button (Gtk.Button, icon "document-save-symbolic")
                        ├─ reset button (Gtk.Button, icon "edit-undo-symbolic")
                        └─ doc expander (Gtk.Expander or Adw.ActionRow subtitle)
```

### 3.2 ConfigMetadata Module

**File:** `src/config/metadata.zig` (new)

This module runs at runtime to produce a flat array of `FieldMeta` records. It iterates `@typeInfo(Config).@"struct".fields` inline at comptime and builds a runtime slice:

```zig
pub const FieldKind = enum {
    bool,
    optional_bool,
    int,
    float,
    @"enum",
    packed_flags,
    string,
    repeatable,
    complex,   // fallback — read-only display
};

pub const EnumVariant = struct { name: []const u8 };

pub const FieldMeta = struct {
    name: []const u8,               // e.g. "font-size"
    kind: FieldKind,
    docs: []const u8,               // from help_strings.Config.<name>, or ""
    // For enum kinds:
    variants: []const EnumVariant,  // comptime-built slice, static lifetime
    // For bool/optional-bool/int/float/string: empty
};

// Static array, comptime-initialized:
pub const fields: []const FieldMeta = comptime build: { ... };
```

The comptime `build` block uses `inline for` over `@typeInfo(Config).@"struct".fields`, inspects `field.type` via `@typeInfo` to assign `FieldKind`, and for enum types also builds a `[]EnumVariant` from the enum's `.fields`. Doc strings are pulled from `help_strings.Config` using `@hasDecl` / `@field`. This array has static lifetime (comptime data), so it requires no allocator.

### 3.3 ConfigEditorWindow

**File:** `src/apprt/gtk/class/config_editor_window.zig` (new)
**Blueprint:** `src/apprt/gtk/ui/1.5/config-editor-window.blp` (new)
**GObject name:** `GhosttyConfigEditorWindow`
**Parent:** `adw.ApplicationWindow`

Key methods:

| Method | Description |
|---|---|
| `new(app: *Application) *Self` | Allocates, resolves config path, clones live config, starts file monitor |
| `present()` | Calls `gtk.Window.present()` |
| `applyKey(key: Key, raw_value: []const u8) !void` | Parses the raw string into a scratch `Config` via `loadIter`, extracts the field, copies it into `Private.live_config` |
| `persistKey(key: Key, raw_value: []const u8) !void` | Opens the config file, rewrites it using `FileFormatter` with a patched config |
| `reloadFromFile() !void` | Calls `Config.load` and refreshes the editor model |
| `onFileChanged(...)` | Signal handler for `gio.FileMonitor` changed signal — shows conflict dialog |
| `showConflictDialog()` | Creates an `adw.AlertDialog` with Reload / Overwrite / Cancel choices |

**Singleton enforcement:** Application holds an optional `?*ConfigEditorWindow` in its private data. If non-null when action is triggered, call `present()` instead of creating a new window.

### 3.4 Row Widget per Option

The per-row widget is a **`Adw.ActionRow`** (from libadwaita). Each row:
- `title` = key name (hyphenated, monospace via CSS)
- `subtitle` = first line of doc text (truncated, full text on expand or tooltip)
- `suffix` child = type-dispatched value editor + Save + Reset buttons

Value editors by `FieldKind`:

| Kind | Widget |
|---|---|
| `bool` | `Gtk.Switch` |
| `optional_bool` | `Gtk.DropDown` with items: "default", "true", "false" |
| `int` | `Gtk.SpinButton` (integer mode) |
| `float` | `Gtk.SpinButton` (float mode, step 0.5) |
| `enum` | `Gtk.DropDown` with string list from `FieldMeta.variants` |
| `packed_flags` | Multiple `Gtk.CheckButton` (one per flag field) |
| `string` | `Gtk.Entry` |
| `repeatable` | `Gtk.Entry` (comma-separated, or multi-line in a later phase) |
| `complex` | `Gtk.Entry` (raw string, validated on commit) |

### 3.5 Live-Apply vs Persist Logic

```
User changes value
    │
    ├─► mark row as "dirty" (visual indicator, e.g. row CSS class "modified")
    │
    ├─► if instant_reload checkbox is ON:
    │     call applyKey(key, raw) → re-parse one field into live_config
    │     call Application.reloadConfig(.soft) so all surfaces update
    │
    └─► if persist checkbox is ON:
          call persistKey(key, raw) → rewrite config file
          (this may trigger FileMonitor; suppress self-triggered change events
           by recording the mtime before write and ignoring events with same mtime)
```

`persistKey` implementation:
1. Clone `Private.live_config` into a scratch `Config`.
2. Apply the single key edit to the scratch config via `loadIter`.
3. Write the entire scratch config back using `FileFormatter` (with `docs: false`, `changed: false` to produce a complete, formatted file). This is the "auto-format on save" behavior.
4. Flush and close file.

Per-row **Save button**: explicitly persists just that row (overrides global persist checkbox for one key).

Per-row **Reset button**: sets the field back to `Config.default` value. If instant_reload is on, re-applies. If persist is on, rewrites file without the overridden key.

### 3.6 External Change Detection via `gio.FileMonitor`

```zig
// In ConfigEditorWindow.new():
const gfile = gio.File.newForPath(path);
const monitor = gfile.monitor(.none, null, null) orelse return error.MonitorFailed;
_ = gio.FileMonitor.signals.changed.connect(
    monitor, *Self, onFileChanged, self, .{}
);
Private.file_monitor = monitor;
```

`onFileChanged` checks `event_type == .changes_done_hint` (debounced final event) and that the changed file matches `config_path`. It then:
1. Reads the new file mtime.
2. If mtime matches a recently-written mtime (self-triggered write within 2 seconds) → ignore.
3. Otherwise → call `showConflictDialog()`.

`showConflictDialog()` creates an `adw.AlertDialog` with three responses:
- `"reload"` → `reloadFromFile()` — discards all unsaved editor edits
- `"overwrite"` → `persistLiveConfig()` — writes the current editor state back to disk
- `"cancel"` → dismiss dialog, leave both states as-is (editor may be out of sync with disk)

---

## 4. UI Layout

### Config Editor Window

```
┌─────────────────────────────────────────────────────────────────────┐
│  ◀  Ghostty Configuration Editor                        [−] [□] [×] │
├─────────────────────────────────────────────────────────────────────┤
│  [🔍 Filter keys…]                                                  │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ ☑ Instantly reload   ☑ Persist changes                       │  │
│  └───────────────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────────────┤
│  Scrollable list (Gtk.ListView + Adw.ActionRow factory)             │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ font-size                                                   │    │
│  │ Font size in points…              [▲12.0▼]  [💾] [↺]       │    │
│  ├─────────────────────────────────────────────────────────────┤    │
│  │ cursor-style                                                │    │
│  │ The style of the cursor…         [block ▾]  [💾] [↺]       │    │
│  ├─────────────────────────────────────────────────────────────┤    │
│  │ font-family                                                 │    │
│  │ The font families to use…        [____________]  [💾] [↺]  │    │
│  ├─────────────────────────────────────────────────────────────┤    │
│  │ background-opacity        (modified •)                      │    │
│  │ Background opacity, 0–1…         [▲0.95▼]  [💾] [↺]       │    │
│  └─────────────────────────────────────────────────────────────┘    │
│    …                                                                 │
└─────────────────────────────────────────────────────────────────────┘
```

### Blueprint pseudo-spec (`config-editor-window.blp`)

```blueprint
using Gtk 4.0;
using Adw 1;

template $GhosttyConfigEditorWindow : Adw.ApplicationWindow {
  title: _("Ghostty Configuration Editor");
  default-width: 900;
  default-height: 700;

  content: Adw.ToolbarView {
    [top]
    Adw.HeaderBar {
      title-widget: Gtk.SearchEntry search_entry {
        hexpand: true;
        placeholder-text: _("Filter config keys…");
        search-changed => $on_search_changed();
      };
    }

    Gtk.Box {
      orientation: vertical;
      spacing: 0;

      Gtk.Box options_bar {
        orientation: horizontal;
        margin-top: 6;
        margin-bottom: 6;
        margin-start: 12;
        margin-end: 12;
        spacing: 18;

        Gtk.CheckButton instant_reload_check {
          label: _("Instantly reload");
          active: true;
          toggled => $on_instant_reload_toggled();
        }

        Gtk.CheckButton persist_check {
          label: _("Persist changes");
          toggled => $on_persist_toggled();
        }
      }

      Gtk.Separator { orientation: horizontal; }

      Gtk.ScrolledWindow {
        vexpand: true;
        hexpand: true;

        Gtk.ListView config_list {
          show-separators: true;
          single-click-activate: false;
          // model and factory set in code (Gio.ListStore of ConfigEntryObject)
        }
      }
    }
  };
}
```

Row factory template (embedded in code or a separate `.blp` snippet):

```blueprint
template Gtk.ListItem {
  child: Adw.ActionRow {
    title: bind template.item as <$GhosttyConfigEntry>.key-name;
    subtitle: bind template.item as <$GhosttyConfigEntry>.doc-summary;
    tooltip-text: bind template.item as <$GhosttyConfigEntry>.doc-full;

    [suffix]
    Gtk.Box {
      orientation: horizontal;
      spacing: 6;
      valign: center;
      // value_widget inserted dynamically in Zig code based on FieldKind
      Gtk.Button save_btn {
        icon-name: "document-save-symbolic";
        tooltip-text: _("Save this key to config file");
        clicked => $on_save_clicked();
      }
      Gtk.Button reset_btn {
        icon-name: "edit-undo-symbolic";
        tooltip-text: _("Reset to default");
        clicked => $on_reset_clicked();
      }
    }
  };
}
```

**`GhosttyConfigEntry`** is a simple `gobject.Object` subclass wrapping a `FieldMeta` index + current string value + dirty flag. The `Gtk.ListView` model is a `gio.ListStore` of `GhosttyConfigEntry` objects filtered by `Gtk.StringFilter` on key name (search bar).

---

## 5. Open Questions / Risks

1. **`adw.PreferencesWindow` vs plain `adw.ApplicationWindow`:** The PreferencesWindow groups fields by page (e.g. "Fonts", "Appearance", "Terminal") and provides a search bar built-in. This would require assigning each key to a section — feasible from the field name prefix convention (all font-* keys together, etc.) but adds scope. **Decision needed from user/maintainer** before implementation starts. The plan defaults to `adw.ApplicationWindow` (simpler, follows inspector pattern).

2. **Repeatable fields** (e.g. `font-family`, `keybind`): These fields accept multiple values and have complex internal types. Showing them as a single comma-joined string entry is lossy. Proper editing requires a list widget with add/remove rows. Recommend deferring full edit to a later phase (show current serialized form read-only in P2, unlock in P6).

3. **`Config.loadIter` side effects:** Parsing a single key through `loadIter` may trigger callbacks, diagnostic collection, or path expansion. The plan's "apply one key" approach uses a scratch `Config` to avoid contaminating the live config until the result is validated. Risk: some field types (e.g. `theme`) trigger file I/O on parse. Testing needed.

4. **Self-triggered `gio.FileMonitor` events:** After a persist write, the file monitor will fire. The mtime-comparison suppression strategy is a heuristic. Linux `inotify` through GIO may report multiple events per write. A more robust approach: set a boolean flag `self.private().writing_file = true` before the write, clear it after, and ignore monitor events when the flag is set. The flag must be cleared on the main thread (GLib main loop).

5. **Config file path resolution:** `config/edit.openPath` creates the file if it doesn't exist. The editor must call this at open time, not at startup. If the user has no config file, the editor should create one on first persist (current `edit.openPath` already does this).

6. **Thread safety:** All GTK operations must be on the main thread. `Config.load` and file I/O should be run via `gio.Task` (GIO async task) to avoid blocking the UI on slow filesystems. Risk level: low for typical SSD users, but correctness matters.

7. **`help_strings` at GTK runtime:** `help_strings` is a comptime-generated module linked into the binary. It is always available at runtime — no additional build wiring needed for the editor. However, the generated strings are Markdown — they should be displayed as plain text (strip `**`, `` ` ``, etc.) or rendered with a minimal Markdown-to-Pango-markup converter.

---

## 6. Phased Implementation

### Phase 1: Comptime Metadata Module
**Goal:** Produce a stable, testable `FieldMeta` array that downstream code can consume.

**Deliverables:**
- `src/config/metadata.zig` — new file with `FieldKind`, `EnumVariant`, `FieldMeta`, and the comptime-built `fields` slice.
- Add `metadata.zig` to the config module exports.
- Add Zig tests: `fields.len > 0`, spot-check that `font-size` has `kind == .float`, `cursor-style` has `kind == .@"enum"` with at least 3 variants, and `font-family` has `kind == .repeatable`.

**Acceptance criteria:** `zig build test -Dtest-filter=metadata` passes. The `fields` array length equals the number of non-`_` fields in `Config` (same count as `key.Key`).

---

### Phase 2: Read-Only Viewer Window
**Goal:** Open a window that lists every config key with its current value and docs. No editing yet.

**Deliverables:**
- `src/apprt/gtk/class/config_editor_window.zig` — `GhosttyConfigEditorWindow` (adw.ApplicationWindow), with `new(app)`, `present()`, singleton guard in Application.
- `src/apprt/gtk/class/config_entry_object.zig` — `GhosttyConfigEntry` GObject wrapping `FieldMeta` index + current serialized value string.
- `src/apprt/gtk/ui/1.5/config-editor-window.blp` — window blueprint (no edit widgets yet, values as read-only `Gtk.Label` in row suffix).
- Register `"open-config-editor"` app action in `Application.startupActions()`.
- Add menu item in `window.blp` main menu (under existing "Open Config" item).
- No build system changes needed beyond registering the new `.blp` and `.zig` in the gresource / build list.

**Acceptance criteria:**
- Choosing "Open Config Editor" from the app menu opens the window.
- All config keys are listed with their current value and first line of doc text.
- The search bar filters the list in real time.
- Window can be closed and reopened; singleton is enforced (second open presents the existing window).

---

### Phase 3: Type-Dispatched Edit Widgets
**Goal:** Replace read-only labels with appropriate edit widgets per `FieldKind`.

**Deliverables:**
- `config_editor_window.zig`: `buildValueWidget(meta: *FieldMeta, current_raw: []const u8) *gtk.Widget` — returns the appropriate widget per kind.
- Implement all six widget types (Switch, DropDown for enums, SpinButton for int/float, Entry for string/complex).
- Wire widget `notify::value` / `toggled` / `changed` signals to mark rows dirty (visual indicator: `"modified"` CSS class on `Adw.ActionRow`).
- Instant-reload checkbox connected: when ON and a widget changes value, call `applyKey` and trigger `Application.reloadConfig(.soft)`.
- Reset button: resets widget to default value (fetched from `Private.default_config`), marks row as clean.

**Acceptance criteria:**
- Changing `font-size` SpinButton with "Instantly reload" ON visibly changes the font size in the terminal within ~100ms.
- Changing `cursor-style` DropDown selects from correct enum variants.
- Reset restores the displayed value to the `Config.default` value.
- No crash or error log for any of the ~200 config fields being rendered.

---

### Phase 4: Persist-to-Disk Logic
**Goal:** Wire the Save button and Persist checkbox to write the config file.

**Deliverables:**
- `persistKey(key, raw_value)`: Clones live config, applies single key via `loadIter`, writes full config with `FileFormatter` to `config_path`.
- `persistLiveConfig()`: Same but for all dirty keys at once.
- Per-row Save button handler calls `persistKey`.
- Persist checkbox: when ON, every value change also calls `persistKey` immediately after `applyKey`.
- After a successful write, clear the "modified" visual indicator on the saved row.
- Error handling: if write fails, show an `adw.Toast` with the error message.

**Acceptance criteria:**
- Changing a value with both checkboxes ON, then closing and reopening Ghostty, shows the new value.
- The written config file is valid (parses without diagnostics).
- The file always ends with a trailing newline (guaranteed by `FileFormatter`).
- No duplicate key entries (FileFormatter writes the whole config, not appends).

---

### Phase 5: File Watcher + Conflict Dialog
**Goal:** Detect external config file changes and offer resolution options.

**Deliverables:**
- `gio.FileMonitor` setup in `ConfigEditorWindow.new()`, teardown in `dispose()`.
- `onFileChanged` signal handler with mtime-based self-write suppression (use a `bool writing_file` flag in Private, set before write, cleared after).
- `showConflictDialog()` using `adw.AlertDialog` with Reload / Overwrite / Cancel.
- `reloadFromFile()`: calls `Config.load`, refreshes `Private.live_config`, rebuilds the `GhosttyConfigEntry` list store.
- `Private.file_monitor` weak-unref'd in dispose to avoid memory issues (follow same pattern as `InspectorWidget.setSurface`).

**Acceptance criteria:**
- While editor is open, external edit of the config file (e.g. `echo "font-size = 16" >> config`) triggers the conflict dialog within ~2 seconds.
- "Reload from file" discards editor state and shows new values.
- "Overwrite" writes the editor's current live config back (external changes lost — confirmed by dialog copy).
- "Cancel" leaves both states as-is (dialog states this clearly).
- No conflict dialog shown when Ghostty itself writes the file via the editor's Save/Persist action.

---

### Phase 6: Polish and Edge Cases
**Goal:** Ship-quality: UX polish, repeatable field editing, keyboard navigation, accessibility.

**Deliverables:**
- Repeatable field rows: show current comma-joined value in `Gtk.Entry`; parse comma-split on commit. Add a "+/-" list UI for `font-family` as a bonus.
- Keyboard navigation: `Tab` moves between value widgets; `Ctrl+S` saves all dirty keys; `Escape` prompts "unsaved changes" confirmation if dirty.
- CSS: add `config-editor.css` (or extend existing CSS) for `.modified` row highlight.
- Accessibility: `Gtk.Label` for key name has accessible description from doc text; all buttons have accessible names.
- Reduce "Persist" scope: offer "Persist only changed keys" mode (uses `FileFormatter` with `changed: true`).
- `adw.Toast` for success confirmations ("Saved font-size = 14").
- Keyboard shortcut: `Ctrl+Shift+,` to open the editor (register in `application.zig` alongside other shortcuts).
- Consider grouping keys by prefix (font-*, cursor-*, background-*, etc.) using `Adw.PreferencesGroup` headers in the list — can be done without switching to `adw.PreferencesWindow`.

**Acceptance criteria:**
- All ~200 config fields are visible and operable without crashes.
- Screen reader (Orca) announces key name and current value when a row is focused.
- The editor window closes cleanly with no memory leaks (confirmed by Valgrind/ASAN run, following the inspector pattern).

---

## Appendix: File Reference Summary

| File | Role |
|---|---|
| `src/config/Config.zig` | Config struct — field types, defaults, `load`, `changed`, `clone` |
| `src/config/key.zig` | Comptime `Key` enum of all user-facing fields |
| `src/config/formatter.zig` | `formatEntry` — type-dispatch serialization |
| `src/config/formatter_file.zig` | `FileFormatter` — full file write with optional docs/changed filter |
| `src/config/edit.zig` | `openPath` — resolve config file path, create if needed |
| `src/config/file_load.zig` | `defaultXdgPath`, `open` helpers |
| `src/helpgen.zig` | Build-time AST parser extracting doc comments → `help_strings` module |
| `src/apprt/gtk/class/inspector_window.zig` | UX template: adw.ApplicationWindow pattern |
| `src/apprt/gtk/class/inspector_widget.zig` | UX template: weak refs, dispose, property notify |
| `src/apprt/gtk/class/application.zig:1444` | Action registration pattern |
| `src/apprt/gtk/class/application.zig:2533` | `reloadConfig` — hard/soft reload |
| `src/apprt/gtk/class/command_palette.zig` | ListView + ListStore + FilterListModel pattern |
| `src/apprt/gtk/class/config.zig` | Existing `GhosttyConfig` GObject wrapping `CoreConfig` |
| `src/apprt/gtk/class/config_errors_dialog.zig` | Signal + dialog pattern |
| `src/apprt/gtk/ui/1.5/inspector-window.blp` | Blueprint template for inspector (direct model) |
| `src/apprt/gtk/ui/1.5/command-palette.blp` | Blueprint template for ListView + filter (direct model) |
