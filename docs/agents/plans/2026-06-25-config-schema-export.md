# Config Schema Export — Design Plan

**Date:** 2026-06-25
**Branch context:** feat/ghostty-tiling
**Author:** Research agent (Claude Sonnet 4.6)

---

## 1. Question Framing

### What We Are Trying to Achieve

When a user opens their `~/.config/ghostty/config` file in any editor — VS Code,
Neovim, Helix, Zed, Sublime Text, IntelliJ IDEA — they should get:

- **Completion** of key names as they type.
- **Value completion** after `=` (enum choices, booleans, valid color syntax, etc.).
- **Hover docs** showing the full doc-comment for a key (Markdown-rendered by the editor).
- **Diagnostics** (red underlines) for unknown keys, invalid enum values, type errors.

### Who Benefits

- End users who edit config manually and currently must consult the online docs or run
  `ghostty +show-config --default --docs` in a separate pane.
- Theme/plugin authors who maintain config snippets and want editor validation.
- Downstream packagers (Flatpak, Homebrew, Nix) who could ship the schema/LSP server
  alongside the binary.

---

## 2. Constraints

### 2.1 Ghostty Config Is Not JSON / TOML / YAML

The ghostty config format is a custom line-oriented `key = value` (or `key = value1,value2`)
format. Key names use hyphens (`font-size`, `font-family`). It has no section headers, no
nesting, and several unusual value types:

| Value type example | Ghostty encoding |
|--------------------|------------------|
| bool | `true` / `false` |
| int / float | `13`, `0.7` |
| enum | `block`, `bar`, `underline` |
| optional | empty RHS = null (`cursor-color =`) |
| color | `#RRGGBB`, named X11 color, `cell-foreground` |
| packed struct flags | `cursor,no-navigation` |
| repeatable | same key multiple times |
| palette entry | `N=COLOR` (e.g. `5=#BB78D9`) |
| key binding | `ctrl+a=copy_to_clipboard` |
| font variation | `wght=700` |

JSON Schema (Draft 2020-12) models JSON; it cannot natively validate a `key = value`
file. This rules out a direct "map the config to JSON Schema and attach to the file" approach.

### 2.2 Ghostty Already Has Comptime Metadata

The existing build pipeline provides two key primitives:

1. **`helpgen.zig`** — walks `Config.zig` with `std.zig.Ast`, extracts all `/// doc-comment`
   blocks above each field, and generates a Zig source file (`help_strings`) where
   `help_strings.Config.<field_name>` is a `[:0]const u8` multiline string.
2. **`formatter.zig` / `formatter_file.zig`** — walks `@typeInfo(Config).@"struct".fields`
   comptime to emit each field's current value. The switch on `@typeInfo(T)` already
   classifies every field type: `.bool`, `.int`, `.float`, `.@"enum"`, `.optional`, `.pointer`
   (strings), `.@"struct"` (packed flags or custom), `.@"union"` (custom union types).

This means **all the raw material** (field names, Zig types, default values, doc strings) is
already accessible comptime. There is no scraping needed.

### 2.3 Fork Status

This repository is a personal fork (branch `feat/ghostty-tiling`). Any tooling developed
here should be architected to be proposable upstream to `ghostty-org/ghostty`. The design
must therefore not rely on fork-specific changes to `Config.zig` or on private build
infrastructure.

### 2.4 Existing Version Metadata Is Informal

`Available since: 1.2.0` appears inline in doc-comment prose, not as a structured annotation.
Parsing it requires a regex over the help string. The compatibility map at `Config.zig:64`
provides the exhaustive list of deprecated/renamed keys.

---

## 3. Survey of Approaches

### 3.1 JSON Schema (Draft 2020-12)

JSON Schema is the de-facto standard for "smart editing of structured text", backed by:
- VS Code (native, via `json.schemas` setting or the JSON Language Server).
- IntelliJ IDEA (native, via Schema mappings).
- Neovim (via `coc-json` or `none-ls` + `jsonls`).
- Helix and Zed (via their respective LSP-json adapters).

**Fatal limitation:** ghostty's config is not JSON. JSON Schema validators work on parsed
JSON object trees. You cannot associate a JSON Schema with a free-form `key = value` file;
the file is not a JSON document. This approach would require either:
(a) a separate "config in JSON" representation (a completely different file format), or
(b) a custom pre-processor that converts the ghostty config to JSON before validation.

Option (a) is a second config format and a maintenance burden. Option (b) means the schema
validation is decoupled from the actual file being edited, breaking the live-editing experience.

**Verdict: Not viable as a primary solution.** Potentially useful as an intermediate
serialization format for tooling pipelines (see section 4.1).

### 3.2 TextMate Grammars / Syntax Highlighting

TextMate grammars (`.tmLanguage.json`) can be used in VS Code, Zed, Helix (via Tree-sitter
or injections), and Sublime Text. They provide **syntax highlighting** of the config file
(coloring key names, `=`, values, `#`-comments).

**Limitation:** No completion, no hover docs, no value validation. Purely cosmetic.

A Tree-sitter grammar for the ghostty config format would be complementary to any LSP-based
solution and is straightforward to write (the grammar is simple). However it is out of scope
for the core schema-export goal.

**Verdict: Useful supplementary artifact but insufficient alone.**

### 3.3 LSP (Language Server Protocol)

A custom `ghostty-config-language-server` binary that speaks LSP 3.17 over stdio provides
completion, hover, and diagnostics to **any editor** with LSP support: Neovim, Helix, Zed,
VS Code, Sublime Text (via `LSP` package), IntelliJ (via LSP plugin). This is the "N+M"
solution — write the server once, reach all editors.

The **kitty terminal emulator** has an in-progress LSP server (`kitty-lsp`) discussed on
GitHub ([kovidgoyal/kitty#9744](https://github.com/kovidgoyal/kitty/discussions/9744)) that
already implements completion of 300+ options, enum value suggestions, diagnostics, and hover
with links to online docs. It demonstrates this approach is practical for a `key = value`
terminal config format.

**Verdict: Best long-term solution. High effort, high value.**

### 3.4 Tree-sitter Grammar

A Tree-sitter grammar enables structural syntax highlighting and navigation in Helix, Zed,
Neovim (nvim-treesitter), and others. The ghostty config grammar is simple enough to write
in an afternoon. Combined with an LSP server, Tree-sitter provides the visual layer while
LSP provides the semantic layer.

Ghostty already has a Tree-sitter grammar for its own configuration format available at
[tree-sitter-ghostty](https://github.com/bezhermoso/tree-sitter-ghostty) (community project).

**Verdict: Good complementary artifact, not a blocker for the schema story.**

### 3.5 Editor-Specific Completions (No LSP)

Each editor has its own completion/snippet format:
- Sublime Text: `.sublime-completions` JSON files.
- VS Code: `package.json` `contributes.snippets` in an extension.
- IntelliJ: Live Templates XML.
- Zed: extensions with `snippets.json`.

These could be generated from an intermediate JSON spec (see section 4.1). They provide
completion of key names but not value validation or hover docs without more work.

**Verdict: Reasonable interim measure; superseded by LSP.**

### 3.6 Tradeoffs Summary

| Approach | Completion | Hover Docs | Validation | Effort | Editors Covered |
|---|---|---|---|---|---|
| JSON Schema alone | No (wrong format) | No | No | Low | None effectively |
| TextMate grammar | No | No | No | Low | All (syntax only) |
| Editor-specific snippets | Keys only | No | No | Medium | Per editor |
| Intermediate JSON spec | Keys only (generated) | Via generated snippets | No | Medium | All (as source for generators) |
| **LSP server** | Keys + values | Yes | Yes | High | All |
| LSP + Tree-sitter | Keys + values | Yes | Yes | High + Low | All (best UX) |

---

## 4. Proposed Architecture

### 4.1 Intermediate JSON Spec ("schema.json")

The single source of truth is a machine-readable JSON file emitted by a new Zig build
step. This JSON spec is consumed by downstream generators (per-editor configs, the LSP
server, the Tree-sitter query, docs pipelines).

**Conceptual shape of each entry:**

```json
{
  "key": "font-size",
  "type": "float",
  "default": "12",
  "description": "Font size in points. ...",
  "since_version": "1.0.0",
  "deprecated": false,
  "deprecated_replaced_by": null,
  "repeatable": false,
  "allowed_values": null,
  "platform": ["linux", "macos", "windows"]
}
```

For enum types, `allowed_values` becomes an array of strings. For packed-struct flag types,
it becomes an array of flag names with optional `no-` prefix. For `Color`, it becomes a
description of the accepted syntax. For `RepeatableString`, `repeatable` is `true`.

**Type classification map (Zig → JSON `type`):**

| Zig type info | JSON `type` value |
|---|---|
| `.bool` | `"bool"` |
| `.int` | `"int"` |
| `.float` | `"float"` |
| `.@"enum"` | `"enum"` |
| `.optional` with inner type | `"optional:<inner>"` |
| `[]const u8` / `[:0]const u8` | `"string"` |
| packed struct (all bool fields) | `"flags"` |
| `RepeatableString` | `"repeatable_string"` |
| `Color` | `"color"` |
| `Palette` | `"palette"` |
| custom struct/union with `parseCLI` | `"custom"` |

### 4.2 Build Step: `zig build emit-config-schema`

A new `schemaGen.zig` binary (parallel to `helpgen.zig` and `webgen_config.zig`) runs at
build time, importing `Config.zig` and `help_strings`, and writes the JSON spec to
`zig-out/share/ghostty/schema/config.schema.json`.

The binary structure mirrors `helpgen.zig`:

```
src/schemagen.zig              ← new entry point
src/build/GhosttySchema.zig    ← new build step (mirrors HelpStrings.zig / GhosttyWebdata.zig)
```

Implementation walkthrough:

1. `inline for (@typeInfo(Config).@"struct".fields)` — enumerate all config fields.
2. Skip fields with `field.name[0] == '_'` (internal).
3. `@typeInfo(field.type)` — classify the Zig type into a JSON `type` string.
4. For `.@"enum"` types: `@typeInfo(EnumType).@"enum".fields` gives all variant names.
5. For packed structs: `@typeInfo(PackedType).@"struct".fields` gives all flag names.
6. Default value: serialize using the existing `formatter.formatEntry` logic to get the
   string representation ghostty itself would write.
7. Doc-comment: look up `@field(help_strings.Config, field.name)` (same as all other
   build tools do).
8. `since_version`: extract from the doc-comment with a simple regex `Available since: (\d+\.\d+\.\d+)`.
9. `deprecated` / `deprecated_replaced_by`: derived from the `Config.compatibility`
   static map at `Config.zig:64` — any key in that map is a deprecated alias.
10. Output JSON array to stdout; captured by the build step.

### 4.3 LSP Server: `ghostty-config-lsp`

The LSP server is the highest-value deliverable. It can be implemented in one of two ways:

**Option A — Zig binary, reads schema.json at startup**

- Standalone Zig binary; zero runtime dependencies.
- Reads the pre-generated `schema.json` (or a copy embedded at compile time via
  `@embedFile`).
- Speaks LSP 3.17 over stdio using a simple JSON-RPC implementation.
- Implements `textDocument/completion`, `textDocument/hover`, `textDocument/diagnostic`.
- Can be shipped in the same Flatpak / package as ghostty itself.
- Precedent: the `ghostty +show-config` and `ghostty +explain-config` commands already
  demonstrate that ghostty can expose its config metadata via CLI. The LSP server is a
  natural extension.

**Option B — TypeScript/Node binary, reads schema.json**

- Uses `vscode-languageserver` npm package (Microsoft's reference LSP server library).
- Faster to prototype (richer LSP library ecosystem); harder to ship without Node.
- Suitable if the intent is to publish a VS Code extension (which bundles its own Node).

**Recommendation:** Option A for upstream inclusion (no new runtime dependency, same
language as ghostty). Option B for a fast prototype or a standalone VS Code extension.

**LSP server — key request handlers:**

| LSP method | Implementation |
|---|---|
| `initialize` | Return capabilities: completion, hover, diagnostics |
| `textDocument/didOpen`, `didChange` | Parse the config text; cache the parse tree |
| `textDocument/completion` | At line start → suggest keys; after `=` → suggest values for that key |
| `textDocument/hover` | Find key under cursor → return `description` from schema.json |
| `textDocument/diagnostic` | Unknown keys, invalid enum values, type errors |

Parser: the ghostty config format is simple enough to parse line by line
(`key = value`; skip `#` comments and blank lines). No need for Tree-sitter in the server.

### 4.4 Downstream Generator Pipeline

Given `schema.json`, thin generators produce editor-specific artifacts:

```
schema.json
├── ghostty-config-lsp          ← speaks LSP 3.17 (covers Neovim, Helix, Zed, VS Code, IntelliJ, Sublime)
├── gen_sublime_completions.py  ← .sublime-completions JSON for Sublime without LSP
├── gen_vscode_snippets.py      ← VS Code snippets extension skeleton
└── gen_helix_queries.scm       ← Helix highlight queries (if Tree-sitter grammar exists)
```

Each generator is a short script (50–100 lines) that reads `schema.json` and writes the
editor-specific format. They can live under `src/build/schema/` in the ghostty tree.

---

## 5. Per-Editor Breakdown

### 5.1 VS Code

**Artifact needed:** A VS Code extension containing:
- A `TextDocumentContentProvider` or `languages.registerCompletionItemProvider` that
  activates for files matching `**/ghostty/config` and similar globs.
- Alternatively, configure the VS Code LSP client extension to launch `ghostty-config-lsp`.

**Simplest path:**
1. Publish a minimal VS Code extension (`vscode-ghostty`) that ships the `ghostty-config-lsp`
   binary (or downloads it on install) and wires it up as the language server for files named
   `ghostty/config` or with a `# ghostty config` shebang comment.
2. The extension can also include a TextMate grammar for syntax highlighting.

**Effort:** Medium. The LSP server does all the heavy lifting; the VS Code wrapper is thin.

### 5.2 Neovim / Vim

**Artifact needed:** An entry in `nvim-lspconfig`'s server registry for `ghostty_config_ls`,
pointing to the `ghostty-config-lsp` binary and activating on `filetype=ghostty`.

User setup after upstream acceptance:
```lua
require('lspconfig').ghostty_config_ls.setup{}
```

The filetype detection autocommand (`*.ghostty` or path-based detection for
`~/.config/ghostty/config`) needs to be in a small Vimscript/Lua snippet distributed with
ghostty or as a separate plugin.

**Effort:** Low (once LSP server exists). The `nvim-lspconfig` PR to register the server is
a few lines; the filetype detection snippet is trivial.

### 5.3 Helix

**Artifact needed:** An entry in Helix's `languages.toml` (or user's `~/.config/helix/languages.toml`):

```toml
[[language]]
name = "ghostty"
scope = "source.ghostty"
file-types = [{glob = "**/ghostty/config"}]
language-servers = ["ghostty-config-lsp"]

[language-server.ghostty-config-lsp]
command = "ghostty-config-lsp"
```

Helix also natively supports Tree-sitter. If a `tree-sitter-ghostty` grammar is registered,
Helix gets syntax highlighting without any extension mechanism.

**Effort:** Very low once LSP server and/or Tree-sitter grammar exist. User config is the
only requirement; no plugin system.

### 5.4 Zed

**Artifact needed:** A Zed extension (Rust crate) that registers the `ghostty` language and
wires up `ghostty-config-lsp` as its language server. Zed extensions can include a
`languages/ghostty/config.toml` that defines the language, and a `src/lib.rs` that downloads
or locates the LSP binary.

Zed's extension API is documented at `zed.dev/docs/extensions/languages`. The ghostty
extension would also ship a `highlights.scm` for Tree-sitter-based highlighting.

**Effort:** Medium. Zed's extension API is stable but requires a Rust wrapper crate.

### 5.5 Sublime Text

**Artifact needed:**
- A `Ghostty.sublime-syntax` file for syntax highlighting.
- A `ghostty.sublime-completions` file for key name completion (generated from
  `schema.json`).
- OR: Configure the `LSP` package to launch `ghostty-config-lsp` for files matching the
  ghostty config pattern.

The LSP approach is again simplest — `LSP` is a popular Sublime package and requires only
a JSON config snippet to wire up a new server.

**Effort:** Low (LSP client config) or Medium (native Sublime package).

### 5.6 IntelliJ IDEA / JetBrains IDEs

**Artifact needed:** A JetBrains plugin (Kotlin/Java) that registers the ghostty config
as a custom file type and wires up `ghostty-config-lsp` via the built-in LSP client
(available since IntelliJ 2023.2 for Ultimate, 2024.1 for Community). Alternatively, users
can manually configure the LSP client in Settings → Tools → Language Servers.

**Effort:** Low for users (manual LSP client config); Medium for a published plugin.

---

## 6. Build-Tool Sketch

```
# New build step (mirrors GhosttyWebdata)
zig build emit-config-schema
  → zig-out/share/ghostty/schema/config.schema.json

# Build the LSP server binary
zig build ghostty-config-lsp
  → zig-out/bin/ghostty-config-lsp

# Generate editor artifacts (run from repo root)
python3 src/build/schema/gen_sublime_completions.py \
    zig-out/share/ghostty/schema/config.schema.json \
    > dist/Ghostty.sublime-completions

python3 src/build/schema/gen_vscode_snippets.py \
    zig-out/share/ghostty/schema/config.schema.json \
    > dist/vscode-ghostty/snippets/ghostty.json
```

The `config.schema.json` would be published alongside each ghostty release (e.g., on the
GitHub release page and at `https://ghostty.org/schema/config.schema.json`) so editors
and tools can fetch it without building from source.

In the Flatpak build, `ghostty-config-lsp` would be packaged as an additional binary in
`/app/bin/`, available to editors that invoke it via `PATH`.

---

## 7. Phased Rollout

### Phase 1 — Intermediate JSON Spec (low risk, immediate value)

1. Write `src/schemagen.zig`: walk `Config.zig` fields comptime + AST, emit JSON.
2. Add `GhosttySchema.zig` build step: `zig build emit-config-schema`.
3. Publish `config.schema.json` with the next ghostty release.
4. Write simple Python generator scripts for Sublime completions and VS Code snippets.

**Deliverables:** `config.schema.json`, Sublime completions, VS Code snippets.
**Estimated effort:** 2–3 days of implementation.

### Phase 2 — LSP Server (core value)

1. Write `ghostty-config-lsp` in Zig (or TypeScript for a faster prototype).
2. Implement `initialize`, `textDocument/completion`, `hover`, `diagnostic`.
3. Embed `config.schema.json` via `@embedFile` for zero-dependency distribution.
4. Register the server in `nvim-lspconfig`; publish editor setup docs.

**Deliverables:** `ghostty-config-lsp` binary, nvim-lspconfig entry, user docs.
**Estimated effort:** 1–2 weeks.

### Phase 3 — Editor Packages (distribution)

1. Publish a VS Code extension (`vscode-ghostty`) bundling the LSP server.
2. Submit a Zed extension (`zed-ghostty`) to the Zed extension registry.
3. Contribute the Tree-sitter grammar (if `tree-sitter-ghostty` is not already merged
   upstream) to `nvim-treesitter` and Helix.

**Deliverables:** Published VS Code and Zed extensions.
**Estimated effort:** 1 week per extension.

### Phase 4 — Upstream Adoption

1. Open a PR to `ghostty-org/ghostty` adding `emit-config-schema` and
   `ghostty-config-lsp` as first-class build targets.
2. Integrate `config.schema.json` into the ghostty website's tooling pipeline.
3. Deprecate the ad-hoc per-editor workaround docs in favor of the LSP-first doc page.

---

## 8. Open Questions

### 8.1 Schema Version Stability

`config.schema.json` needs a version field. When a new ghostty version adds or removes
keys, the schema changes. Consumers (editor extensions) that pin a schema version may
show stale completions or false-positive diagnostics. A versioning policy (semver mirroring
ghostty's own release version?) and a `$schema` self-reference URL need to be established.

### 8.2 Distribution via Flatpak

The ghostty Flatpak sandbox restricts which binaries are accessible from the host. If a
user runs VS Code on the host and ghostty via Flatpak, the `ghostty-config-lsp` binary
inside the Flatpak sandbox is not on the host PATH. This requires either:
(a) Shipping a separate `ghostty-config-lsp` binary outside the Flatpak (e.g., in the
    Flatpak's exported binaries), or
(b) Distributing `ghostty-config-lsp` as a separate package/binary independent of the
    Flatpak.

This is the same problem that affects the `ghostty +explain-config` CLI when used from the
host side.

### 8.3 Platform-Conditional Keys

Several config keys are marked `GTK only` or `macOS only` in their doc-comments.
The LSP server should suppress completion of platform-irrelevant keys (e.g., don't
suggest `adw-*` on macOS). This requires either runtime platform detection or per-platform
schema variants (`config.linux.schema.json`, `config.macos.schema.json`).

### 8.4 Upstream Acceptance Likelihood

The ghostty project may have preferences about which tools ship alongside the main binary.
An LSP server adds a non-trivial maintenance surface. The intermediate JSON spec is almost
certainly acceptable; the LSP server may be kept as a separate repository. It's worth
opening a discussion issue before investing Phase 2 effort.

### 8.5 `since_version` Extraction Reliability

The version metadata is embedded in prose (`Available since: 1.2.0`). A regex over
`help_strings.Config.<field>` will cover most cases but may miss or misparse edge cases
(e.g., `(Available since: 1.2.0)` inline, `Available in: 1.2.0`, or version numbers in
value-specific sub-bullets). A cleanup pass over `Config.zig` to standardize the annotation
format before writing the parser would improve reliability.

### 8.6 Key Binding and Palette Value Schemas

`keybinds` and `palette` entries have sub-syntax (e.g., `keybinds = ctrl+a=copy_to_clipboard`)
that goes beyond simple `key = scalar-value`. The LSP server would need to parse these
sub-grammars to provide value completion for keybind actions and palette indices. This is
non-trivial and may be deferred to a Phase 2b.

---

## 9. Related Prior Art

| Project | Approach | Source |
|---|---|---|
| `kitty-lsp` (WIP) | LSP server for `kitty.conf` (Python); completion, hover, diagnostics | [kovidgoyal/kitty#9744](https://github.com/kovidgoyal/kitty/discussions/9744) |
| Alacritty | TOML config; no official JSON Schema; community workarounds | [alacritty.org](https://alacritty.org) |
| WezTerm | Lua config; `wezterm-types` project provides LuaCATS annotations for LuaLS | [wezterm-types](https://github.com/DrKJeff16/wezterm-types) |
| Helix editor | TOML config; no dedicated LSP; completions via TOML LSP | n/a |
| Ghostty `+explain-config` | CLI that prints docs for a single key (uses `help_strings`) | `src/cli/explain_config.zig` |
| Ghostty `webgen_config` | Emits MDX docs for the website by walking `Config.zig` fields | `src/build/webgen/main_config.zig` |

The `kitty-lsp` project is the closest analogue. Its architecture (Python script that loads
a statically known set of option definitions and speaks LSP over stdio) maps directly to
the proposed `ghostty-config-lsp`. The main difference is that ghostty can emit its schema
from comptime reflection rather than maintaining a separate hand-written option list.
