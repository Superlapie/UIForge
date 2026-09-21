# Layered materials

Use PrimaryButton for sapphire enamel and SecondaryButton for smoked glass.
Both share nine-slice state artwork. Theme keys hover_texture, pressed_texture,
and disabled_texture select artwork using the base slice margins.
Window, panel, and inset styles use translucent directional lighting.
These are native StyleBoxTexture resources, not backdrop-blur shaders.
The supplied atlas reference is retained separately in `examples/references` for comparison.
The original compact skeletons remain in `examples/specs`; the populated parity work is in `examples/atlas`.

Research references:
- [MMORPG concept](https://www.behance.net/gallery/216496143/MMORPG-UI-Design-Concept)
- [Dark Fantasy HUD](https://canisius-ui.com/project-hud)
