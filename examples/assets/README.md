# Example assets

The demonstration documents use original procedural SVG frame art, item icons, a map plate, and an armor silhouette so the examples exercise the same layered visual language as a premium fantasy MMO without copying copyrighted game art or fonts. `aether_gem.svg` is also a small original, redistributable drag/drop fixture for the asset browser. Drop project-owned textures, icons, fonts, or materials here and reference them from JSON with `res://examples/assets/...`.

The HUD frame, medallion, status tracks/fills, semantic resource icons, action slots, and framed panel assets are separate compositional pieces. Production projects can replace any piece without changing document structure or runtime binding IDs.

For ornate frames, use the Nine-slice dock to capture texture margins and then set a theme style to a `StyleBoxTexture` payload. Missing assets are reported as validation errors and do not crash the editor.
