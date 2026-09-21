# Zeal UI Atlas package

This package contains native Godot scenes ready to instantiate, editable `*.ui.json` sources for UIForge, the artwork and fonts those scenes reference, and the complete atlas composition.

The package is intentionally isolated under `client/content/ui/zeal_ui_atlas`. Copy this directory into a Godot project at the same path. The generated scenes do not require the UIForge editor plugin at runtime.

The canonical interface names are in `manifest.json`. Each interface has a matching source file in `interfaces/` and generated scene in `scenes/`.

For AI or tooling, start with `manifest.json`, then inspect the named source document. Stable node IDs, action identifiers, and binding identifiers are preserved in the source and generated scene metadata. Runtime values and game behavior remain owned by the game.

The complete reference composition is `19_complete_ui_atlas` / `complete_ui_atlas.tscn`. The gameplay additions are `20_enemy_target_frame`, `21_gameplay_sidebar_collapsed`, and `22_gameplay_sidebar_expanded`; the bottom resource HUD remains the authoritative always-on combat HUD and no extra skill/action bar is included. Individual screens are named by domain and purpose, for example `02_backpack_inventory` and `13_settings_options`.

The atlas reference image is included under `reference/` for comparison only. It is not referenced or rendered by the generated scenes.
