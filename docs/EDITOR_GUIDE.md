# Human editor guide

## Open and create

Open the repository in Godot 4.7+ and enable the UIForge plugin. Use **New** to choose a blank window or a populated atlas screen template, **Open** for an existing `*.ui.json`, and **Save** to choose its source path. The status bar shows the dirty marker and source path.

The studio is organized as a compact development tool:

- left: hierarchy and stable IDs
- center: design canvas
- right: scrollable typed inspector for layout, Control/CanvasItem, content, typography, style, interaction, accessibility, and metadata
- bottom: reusable components, searchable draggable assets, theme tokens, nine-slice preview, diagnostics
- toolbar: document actions, state preview, viewport preset, reference overlay, fit

## Authoring

Select a component in the Components dock and choose **Add selected**. The component is added to the selected node (or the document root) as a semantic document node. Change its layout, Godot-facing properties, text, assets, style, action, binding, and metadata in the typed inspector. Applying the inspector is one undoable operation. The hierarchy supports selection, reparenting by drag, reorder controls, visibility, locking, duplicate, and delete; the canvas and hierarchy stay synchronized.

Canvas interactions:

- left-click selects; Ctrl/Cmd-click multi-selects
- middle mouse pans
- wheel zooms around the cursor
- drag moves the selected element using grid snapping
- drag the lower-right handle resizes it
- Delete removes the selected node
- Ctrl/Cmd+D duplicates it
- F focuses the selection
- **Fit** frames the design viewport

Drag a texture, SVG, font, material, or resource from the **Assets** tab onto the canvas. Textures placed on empty canvas become `Texture` document nodes with stable IDs; textures/fonts/materials dropped onto compatible selected nodes become resource references. The same asset can also be dropped into a resource field in the inspector.

Use the toolbar state selector to preview normal, hover, pressed, focused, disabled, and selected styling without launching the MMO. Use **Preview** to compile the same document to a temporary scene and open it in an isolated Godot window; native controls can receive normal hover, press, focus, and scroll behavior there. Use the viewport selector to check common resolutions, or **Custom…** to enter any target width and height; fit/viewport/integer scale modes are applied to the canvas preview.

## Theme and tokens

The included `dark_fantasy` theme provides colors, spacing, radii, typography sizes, slot sizes, shadows, glows, component styles, and state styles. Prefer tokens in source JSON. Semantic components use the theme automatically.

HUD authoring uses the same document model. Add `CombatHUD` as the compact root, then compose `HealthBar`, `PrayerBar`, `RunBar`, `SpecialBar`, `HUDMedallion`, and `ActionSlot` controls. Progress controls expose separate track and fill style fields, so a resource can change color and material without replacing its normal Godot `ProgressBar` behavior.

For the in-game RuneScape layout, use the `EnemyTargetFrame` template for the combat-only enemy card and the `GameplaySidebar` templates for the right-side tab rail. The target frame is anchored near the top center and includes the target name, level, health ratio/value, and status effect slots. The sidebar ships as a narrow collapsed rail plus an expanded inventory example; tabs expose stable IDs and panel/action metadata so the game can open its existing inventory, equipment, prayer, magic, skills, quest, social, and settings surfaces. These templates leave the existing bottom resource HUD in place and intentionally do not create a second skill/action bar.

Use the inspector’s **Effect presets JSON** field for reusable `hover_highlight`/`gold_glow` references or project-owned effect data. Generated scenes preserve this as metadata; custom `ShaderMaterial` resources remain ordinary Godot assets.

## Nine-slice styles

The **Nine-slice** bottom tab accepts a frame texture by file dialog or drag/drop, exposes left/top/right/bottom margins, lets you drag the blue guides, previews 320×180/640×360/1024×512 targets, and saves a named reusable `StyleBoxTexture` style into `theme_overrides.styles`. Assign that style name to a node’s **Style reference** field; the compiler emits a normal Godot `StyleBoxTexture` subresource.

Window and panel nodes also accept compositional `decorations`: named texture ornaments become ordinary child Controls, so corners, title ornaments, separators, and top/bottom flourishes remain independently editable and resource-addressable.

The typed inspector covers the common Godot 4.7 `Control`/`CanvasItem` and built-in control properties. It also enumerates the selected native Godot class properties under **Godot Native Properties**, so specialized and newer 4.x values can be edited directly and saved into `properties.godot_overrides`. For bulk or unusual values, use **Godot property overrides (JSON)** in the Advanced category. Keys are native Godot property paths (including `theme_override_*` paths). Resource values can use `{ "$resource": "res://path", "type": "Texture2D" }`; node paths can use `{ "$node_path": "../Target" }`. This keeps the authoring format forward-compatible without requiring the editor to be rebuilt for every engine property addition.

## Reference overlay

Choose **Reference**, select a local image, and the canvas displays it behind the authored controls. The document stores path, opacity, scale, position, visibility, and lock metadata. References are authoring aids and are not compiled into the generated scene.

## Mock data and preview

Mock values let a grid, bank, quest list, or stats panel show representative content without a server. Keep them in `mock_data`; they are not a runtime data contract. The original `examples/specs` documents are intentionally skeleton-first: empty slot placeholders, generic structural rows, polished neutral empty-state text, and explicit binding/action metadata. Add mock records or visible `{{...}}` templates only when you need to judge populated-state spacing; do not treat them as real MMO content.

## Validate and build

**Validate** displays structured diagnostics in the bottom dock. Fix duplicate IDs, unknown types, missing tokens, broken resources, invalid layouts, and other errors before building. Warnings identify likely overflow, clipping, small targets, or unnecessary hardcoded styling.

**Build** generates a normal `.tscn` beside the source document. Generated files include a marker and stable metadata. Edit the JSON source, then rebuild; do not hand-edit generated scenes.

For image output, use the CLI render path:

```sh
./scripts/ui render examples/specs/inventory.ui.json --viewport 1920x1080 --state hover
./scripts/ui render examples/specs/inventory.ui.json --reference concept.png --diff .aether/renders/inventory.diff.png
```

The PNG is deterministic for a fixed source, theme, resources, viewport, and preview state. On display-less Linux, `scripts/ui` automatically uses `xvfb-run` when available.

All meaningful canvas changes use the Godot editor `UndoRedo` object when available. Saving is atomic through a temporary file replacement.

## Populated atlas and native canvas

See [Atlas authoring](ATLAS_PARITY.md) for the new screen templates, native rendered canvas, sprite-region inspector, and visual parity notes.
