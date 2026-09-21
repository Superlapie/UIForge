# AI authoring guide

AI agents should work entirely through files and `scripts/ui`; they do not need to operate the Godot editor.

## Preferred workflow

1. Inspect available capabilities, components, and theme tokens.
2. Reuse existing components and token references.
3. Write a readable `*.ui.json` document with stable IDs.
4. Validate and fix diagnostics.
5. Render at the target viewport when Godot is available.
6. Inspect the screenshot or generated scene and iterate with `get` / `set`.
7. Build the final `.tscn`.

```sh
./scripts/ui capabilities
./scripts/ui inspect examples/specs/inventory.ui.json document
./scripts/ui inspect examples/specs/inventory.ui.json tokens
./scripts/ui inspect examples/specs/inventory.ui.json components
./scripts/ui inspect examples/specs/inventory.ui.json node inventory_grid
./scripts/ui validate my_screen.ui.json
./scripts/ui render my_screen.ui.json --viewport 1920x1080 --output .aether/renders/my_screen_1920x1080.png
./scripts/ui build my_screen.ui.json
```

Use `--state normal|hover|pressed|focused|disabled|selected` to render a specific visual state. For reference comparison, add `--reference path/to/reference.png --diff .aether/renders/my_screen.diff.png`. The reference is comparison input only and is never compiled into the runtime scene.

Every command prints JSON. A failure has `success: false` and structured `errors`; validation diagnostics include `severity`, `code`, `message`, `node`, and `recommendation` where available.

## Small document example

```json
{
	"schema_version": 1,
	"name": "character_stats",
	"viewport": {"width": 1920, "height": 1080, "scale_mode": "fit"},
	"theme": "dark_fantasy",
	"root": {
		"id": "stats_window",
		"type": "WindowFrame",
		"layout": {"position": [420, 180], "size": [1080, 620]},
		"children": [
			{
				"id": "stats_title",
				"type": "Label",
				"layout": {"position": [32, 28], "size": [500, 36]},
				"properties": {"text": "CHARACTER STATS", "font_size": "$font_size.title", "color": "$colors.gold"}
			},
			{
				"id": "health_bar",
				"type": "StatusBar",
				"layout": {"position": [32, 110], "size": [680, 30]},
				"properties": {"value": 82, "min_value": 0, "max_value": 100},
				"binding": "player.health"
			},
			{
				"id": "close_button",
				"type": "PrimaryButton",
				"layout": {"position": [860, 540], "size": [160, 44]},
				"properties": {"text": "CLOSE"},
				"action": "character_stats.close"
			}
		]
	}
}
```

Use `$colors.text_primary`, `$spacing.md`, `$font_size.heading`, and other tokens from the active theme rather than arbitrary hex values. Semantic components automatically select coherent styles. A node may also use `states` for `hover`, `pressed`, `focused`, `disabled`, and `selected`.

Use `transitions` for lightweight runtime motion. The compiler preserves the configuration as `metadata/aether_transitions`, and `AetherRuntime.play_transition()` provides the corresponding Tween helper. Supported presets are `fade`, `scale`, `slide`, `hover`, `button_press`, and `panel_reveal`.

Use `effects` for restrained reusable visual effect references. Values may be a theme effect name, an object, or an array; the compiler preserves them as `metadata/aether_effects`. The included theme exposes `hover_highlight` and `gold_glow`. Use `properties.material` or `properties.godot_overrides` for project-owned `ShaderMaterial` resources when a custom shader is needed.

The `ui capabilities` response exposes the shared typed property catalog and the installed Godot class property list under `native_properties`. Prefer the typed paths (for example `layout.anchors.left`, `layout.size_flags_horizontal`, `properties.font`, `properties.texture`, `properties.focus_mode`, and `metadata`) so an editor user can continue the same work without format conversion. The visual inspector exposes those common fields directly and also lists the remaining editable native properties for the selected Godot control under **Godot Native Properties**.

For a Godot property not present in the typed catalog, set `properties.godot_overrides` to a JSON object whose keys are native Godot property paths. This is the exhaustive escape hatch for specialized/new properties and theme override paths. Example:

```json
"properties": {
  "godot_overrides": {
    "theme_override_constants/outline_size": 2,
    "theme_override_colors/font_color": "$colors.gold",
    "texture_hover": {"$resource": "res://examples/assets/aether_gem.svg", "type": "Texture2D"}
  }
}
```

For structured native values, use an explicit `$type` wrapper so JSON remains unambiguous: `{ "$type": "Vector2", "value": [32, 32] }`, `{ "$type": "Rect2", "value": [0, 0, 128, 64] }`, `{ "$type": "Color", "value": "$colors.gold" }`, or `{ "$type": "Array[NodePath]", "value": ["../A", "../B"] }`. The compiler emits these as ordinary `.tscn` properties/resources; do not duplicate a property already represented by a typed `properties.*` field.

Fantasy frames can stay compositional. Add a `decorations` object to a panel/window; each named entry becomes a normal generated child with a stable derived ID. Use full `layout` when you need exact anchors/offsets, or the shorthand `texture`/`position`/`size` form:

```json
"decorations": {
  "top_ornament": {
    "texture": "res://ui/frames/top_ornament.svg",
    "position": [420, -18],
    "size": [120, 36]
  }
}
```

`ItemGrid` mock slots accept either simple strings or records such as `{"name":"Aether shard","icon":"res://ui/icons/shard.svg","count":12,"rarity":"rare"}`. If an occupied mock slot has no icon, the included dark-fantasy theme uses a deterministic original icon cycle so previews remain legible. Set `properties.show_label` to `true` when a slot should show its name; `rarity` maps to `$rarity.common`, `$rarity.uncommon`, `$rarity.rare`, `$rarity.epic`, or `$rarity.legendary`. The compiler expands these into ordinary `GridContainer`, `Panel`, `TextureRect`, and `Label` children, so runtime code can inspect and replace them normally.

## Stable IDs and operations

IDs are the automation contract. Keep them descriptive and stable: `inventory_grid`, `bank_tabs`, `quest_description`. Never make an agent depend on child indexes.

```sh
./scripts/ui get my_screen.ui.json inventory_grid
./scripts/ui set my_screen.ui.json inventory_grid properties.columns 8
./scripts/ui set my_screen.ui.json withdraw_button properties.text '"Withdraw"'
./scripts/ui add my_screen.ui.json stats_window '{"id":"armor_value","type":"Label","layout":{"position":[32,180],"size":[240,28]},"properties":{"text":"ARMOUR  216","font_size":"$font_size.numeric"}}'
./scripts/ui duplicate my_screen.ui.json primary_button confirm_button
./scripts/ui move my_screen.ui.json confirm_button footer_panel
./scripts/ui delete my_screen.ui.json obsolete_label
```

String values can be passed as JSON strings (`"Withdraw"`) or as plain shell arguments. Quote JSON node objects in the shell.

## Layout rules

- Use containers for repeated content and lists/grids.
- Use `layout.position` and `layout.size` for authored placement, but prefer anchors, minimum sizes, and containers for responsive regions.
- Keep repeated slot dimensions identical.
- Keep interactive controls at least roughly 32px high/wide.
- Keep body text in readable columns; use `autowrap` on descriptions.
- Use one clear primary action hierarchy and no more than a few simultaneous accent colors.
- Ornament boundaries and frames, not important text.

## Mock data and bindings

Mock data is authoring-only. Put deterministic values in `mock_data` on the document or component, such as `item_count`, `occupied_slots`, `items`, or quest lists. A runtime game supplies actual data through its own code.

Use `binding` for a language-neutral value path (`inventory.used`, `player.name`) and `action` for a language-neutral event identifier (`bank.withdraw`). The compiler preserves both as node metadata.

For combat HUDs, use the semantic `CombatHUD`, `HealthBar`, `PrayerBar`, `RunBar`, `SpecialBar`, `HUDMedallion`, and `ActionSlot` components. Resource bars compile to ordinary `ProgressBar` controls with independently selectable `background_style` and `fill_style`; the included theme supplies engraved tracks and distinct health, prayer, run, and special-resource fills. Keep HUD documents compact and anchored to a safe-zone edge rather than making the authored root a full-screen menu.

The RuneScape-style gameplay additions are separate from the persistent resource HUD. `EnemyTargetFrame` is a combat-only target card with `EnemyTargetHealthBar` and repeatable `EnemyStatusEffect` slots; bind it to `combat.target` and let the game hide it when no target is selected. `GameplaySidebar` is the collapsed right-hand rail, while `gameplay_sidebar_expanded.ui.json` demonstrates its expanded panel state. Each tab has a stable ID, tooltip, accessibility name, `panel` metadata value, and language-neutral action (`sidebar.open_inventory`, `sidebar.open_skills`, and so on). The game runtime owns tab switching, panel contents, and expanded/collapsed visibility. Keep the existing bottom resource HUD as the only always-on combat resource treatment; do not add an extra action or skill bar to the game surface.

The shipped examples intentionally use `preview_mode` values such as `empty_slots` and `empty_selection`. They demonstrate proportions, hierarchy, interaction states, and runtime wiring without fabricating item names, player characters, quest lore, currencies, or server state. Follow that pattern for production skeletons: use generic structural labels or neutral dashes in visible text, preserve the real path in `binding`, and add visible `{{...}}` templates or deterministic mock data only when a layout needs representative content for review.

## Validation and build policy

Treat errors as build blockers. Warnings are recommendations about overflow, hit targets, duplicate names, token usage, and similar quality risks. Run `validate` after every meaningful batch of edits, then `render` and `build`.

The schema is versioned at [schemas/aether-ui.schema.json](../schemas/aether-ui.schema.json). V1 migration infrastructure is intentionally kept at the document boundary so future versions can be introduced without silently changing old documents.

## Populated screen templates

`ui capabilities` now includes the shared `templates` catalog. Use `ui new inventory <output.ui.json>` or `ui new ui_atlas <output.ui.json>` to start with populated editable controls. `properties.texture_region` selects `[x, y, width, height]` from a sprite sheet and compiles to native AtlasTexture. See [Atlas authoring](ATLAS_PARITY.md) for examples and limitations.
