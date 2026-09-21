# Zeal atlas authoring

Open `examples/atlas/ui_atlas.ui.json` in UIForge for the complete, editable 1672 × 941 composition. The source is ordinary document nodes, including text, frames, buttons, slots, sprite regions, and connection lines. The supplied reference is stored separately in `examples/references/zeal_atlas.png`; enable the Reference overlay to compare it. Reference art is never compiled into the scene.

The new populated atlas complements the older six empty skeletons in `examples/specs`. It contains the map, backpack, loadout, vault, disciplines, codex, journal, talent constellation, shop, trade, chat, context menu, options, guild, profile, rewards, loot, and combat HUD. The complete atlas and individual screens are independent editable documents: changes to an individual screen do not automatically update the complete atlas.

## Start from a screen

In the editor, choose **New**, select a screen or **Complete UI atlas**, then **Create**. The result is an unsaved copy; Save chooses your own source path. Existing unsaved work still gets the normal discard check. **Blank window** remains available.

The CLI uses the same catalog (`addons/uiforge/components/templates.json`):

```sh
./scripts/ui capabilities
./scripts/ui new inventory examples/my_inventory.ui.json
./scripts/ui new talents examples/my_talents.ui.json
./scripts/ui new ui_atlas examples/my_atlas.ui.json
./scripts/ui inspect examples/my_inventory.ui.json tree
./scripts/ui set examples/my_inventory.ui.json backpack_capacity properties.text '"72 / 120"'
./scripts/ui build-all examples/atlas examples/atlas/scenes
./scripts/ui render examples/atlas/ui_atlas.ui.json --viewport 1672x941 --output .aether/renders/atlas/ui_atlas.png
```

Unknown template names produce `UNKNOWN_TEMPLATE` instead of silently creating an empty window. Preview content is illustrative. Action and binding metadata identify game integration points; game logic supplies inventories, buying, trading, chat, quest progression, and talent unlock rules.

## Edit with the exported appearance

The canvas now renders the compiled scene in a Godot SubViewport. Fonts, native container layout, nine-slice frames, control states, and texture regions use the same compiler as exports. Selection and hit testing use native control bounds, including grid placement and scaled groups. Changes refresh on a 250 ms polling interval; invalid documents fall back to the schematic canvas so they remain editable. Use Validate to diagnose an invalid preview. Preview is still available for interacting with native controls in a separate window.

## Use sprite sheets and portrait crops

Texture controls expose **Sprite region [x, y, width, height] (pixels)** in the Content inspector. Leave it blank to use the complete image. Set the texture resource and a rectangle to use a sprite. For AI authoring:

```json
{
  "id": "sword_art",
  "type": "Texture",
  "layout": {"position": [4, 4], "size": [32, 32], "mouse_filter": 2},
  "properties": {
    "texture": "res://examples/assets/atlas/items.png",
    "texture_region": [0, 0, 362, 362],
    "ignore_texture_size": true,
    "stretch_mode": 5
  }
}
```

The compiler emits a native `AtlasTexture`, with filtering clipped to the region. The portable compiler emits the same resource contract. Regions require numeric coordinates, nonnegative origins, and positive dimensions. The item sheet has four columns and three rows of 362 × 362 pixels. Its order is sword, shield, helmet, potion; herbs, ingots, ring, scroll; crystal, coins, cloak, compass. The same property supports portrait crops without creating edited image files.

## Current visual differences

This is a populated visual starting point, not a pixel-identical reconstruction. The panel arrangement and information hierarchy follow the supplied atlas, but bespoke frame ornaments, the original character portraits, city illustration, individual item shapes, and several control details still differ. The generated knight is reused in profile and shop previews. The HUD retains the earlier component design. Talent links are editable positioned lines; they do not yet reroute automatically when talent nodes move. The dense atlas intentionally triggers small-hit-target warnings; individual game screens can be resized and adapted for the intended input device.

Generated artwork and exact generation prompts are recorded in `examples/assets/atlas/README.md` and `prompts.json`. No screenshot is used as a flattened UI background.

## Verification

`./scripts/test` includes the atlas workflow runner when Godot is available; `python3 tests/test_fallback.py` exercises the portable path. Checks cover template copies, all atlas screen compilation/loading, bad sprite regions, native AtlasTexture values, editor template creation, sprite inspector clearing, native grid placement, and existing editor/compiler workflows. `scripts/render_atlas_studio.gd` captures the actual studio for visual inspection.
