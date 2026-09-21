# UIForge

UIForge is a Godot-native production tool for authoring sophisticated game interfaces. It has one canonical source format: readable `*.ui.json` documents. The visual editor, AI workflow, validator, compiler, and renderer all operate on that same document.

The current `aether_ui` addon path and class namespace are retained for compatibility with existing projects and generated scenes.

It is deliberately not a web editor, Figma bridge, marketplace, or custom runtime renderer. Compiled output is ordinary Godot `.tscn` content with stable node names and metadata for GDScript or C# gameplay code.

## Populated reference atlas

Open [examples/atlas/ui_atlas.ui.json](examples/atlas/ui_atlas.ui.json) for the full Zeal-inspired atlas, or use **New** to create an editable copy of any populated screen. The canvas now previews native compiled controls, and texture regions support illustrated sprite sheets and portrait crops. See [the atlas authoring guide](docs/ATLAS_PARITY.md) for CLI templates, screenshots, and the remaining visual differences.

## Open it

1. Install Godot 4.7 or newer (the project metadata targets 4.7; the authoring APIs intentionally stay compatible with the current 4.x family where possible).
2. Open this directory as a Godot project.
3. Enable the **UIForge** plugin in Project > Project Settings > Plugins.
4. Open the **UIForge** dock. The plugin is also available from the Editor > UIForge menu.

Local verification was run against official Godot 4.7.2. The repository also includes a portable CLI fallback for JSON validation, inspection, mutation, and deterministic `.tscn` generation. PNG rendering and Godot scene loading require a Godot executable.

## AI / command-line workflow

The `scripts/ui` command automatically uses Godot headless when `godot` or `godot4` is available, and otherwise uses the standard-library fallback.
For `render`, it uses `xvfb-run` automatically when available on a display-less Linux machine so SubViewport screenshots can still be captured.

```sh
./scripts/ui capabilities
./scripts/ui validate examples/specs/inventory.ui.json
./scripts/ui inspect examples/specs/inventory.ui.json document
./scripts/ui inspect examples/specs/inventory.ui.json tree
./scripts/ui get examples/specs/inventory.ui.json inventory_grid properties.columns
./scripts/ui set examples/specs/inventory.ui.json inventory_grid properties.columns 10
./scripts/ui build examples/specs/inventory.ui.json examples/scenes/inventory.tscn
./scripts/ui build-all examples/specs examples/scenes
./scripts/ui render examples/specs/inventory.ui.json --viewport 1920x1080 --state hover
./scripts/ui render examples/specs/inventory.ui.json --reference concept.png --diff .aether/renders/inventory.diff.png
```

The commands return compact JSON suitable for an agent. Mutations use stable IDs, not tree indexes. See [docs/AI_AUTHORING.md](docs/AI_AUTHORING.md).

## Create manually

Use **New**, add a reusable component from the Components dock, edit its typed and native Godot properties in the Inspector, drag assets from the Assets dock, choose a viewport and preview state, validate, then build. The canvas supports selection, multi-selection, pan, zoom, grid/snap-aware movement, resize handles, asset placement, hierarchy reparent/reorder, visibility/lock, keyboard delete/duplicate/focus, and a locked reference overlay. Nine-slice styles have their own preview dock.

## Examples

Editable source documents:

- [Inventory](examples/specs/inventory.ui.json)
- [Bank / vault](examples/specs/bank.ui.json)
- [Equipment / loadout](examples/specs/equipment.ui.json)
- [Quest journal](examples/specs/quest_journal.ui.json)
- [Settings](examples/specs/settings.ui.json)
- [Combat HUD / status bar](examples/specs/combat_hud.ui.json)

Generated demonstrations are in [examples/scenes](examples/scenes). They are safe to regenerate and contain a generated marker; edit the JSON source instead.

The original screens in `examples/specs` are compact, atlas-style UI skeletons: repeated slots and rows are intentionally empty, runtime values use polished neutral empty states, and actions/bindings identify the wiring points that the game owns. Optional `{{...}}` template text and mock-data support remain available for layout review, but the examples do not invent MMO items, characters, quest lore, or server state.

## Tests

```sh
./scripts/test
```

With Godot installed, this runs the Godot-native test runner. Without Godot it runs the portable fallback suite, covering JSON round trips, diagnostics, stable-ID operations, capabilities, and compilation of all six original examples plus the populated atlas templates.

More detail is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/EDITOR_GUIDE.md](docs/EDITOR_GUIDE.md), and [docs/GAME_INTEGRATION.md](docs/GAME_INTEGRATION.md).
