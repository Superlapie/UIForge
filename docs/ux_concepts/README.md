# In-game UI placement concepts

These concepts place the Zeal atlas in the actual Enigma gameplay view. They use the current spacious third-person scene as the constraint: the world stays readable, persistent UI stays useful, and full interfaces appear only when the player asks for them.

The three reference images show the intended modes:

- `exploration_always_on.png` — normal movement and navigation.
- `combat_focused.png` — an active target and combat actions.
- `interaction_bank.png` — one focused bank interaction with the world dimmed.

The RuneScape-hybrid variants are the stronger direction for this game:

- `rs_hybrid_exploration.png` — RS2/OSRS spatial grammar with a 2026 visual treatment.
- `rs_hybrid_combat.png` — the same persistent shell plus target and combat-style context.
- `rs_hybrid_bank.png` — a familiar bank interaction with inventory attached as one task.

The images are layout references. They are not flattened UI backgrounds and do not replace the native Godot scenes.

## Stable screen anchors

Use the same anchors at every resolution. Scale the contents inside the anchors; do not move a feature to a different corner just because the viewport changed.

| Anchor | Persistent or contextual content | Guidance |
| --- | --- | --- |
| Bottom center | Health, prayer, run energy, special resource and action slots | Always-on during movement and combat. Keep the player’s path and feet visible. Bars use the same order and colors everywhere. |
| Top right | Minimap / compass | Always-on while navigating. Keep it compact and show only player, route, party and relevant destination markers. |
| Below minimap | Active objective tracker | One quest title plus up to three short objectives. It disappears when no objective is active. |
| Bottom left | Chat | Collapsed to a single tab or one-line preview. Expand only when focused or when a new message requires attention. |
| Upper center | Target frame | Appears only with a selected hostile, friendly target, or boss. Offset it from the player and horizon so it never hides the encounter. |
| Center | Inventory, bank, equipment, shop, trade, settings, codex, talents and journal | One primary window at a time. Dim the world behind it and suspend combat input. |
| Screen edge near an interaction | Context menu | Opens at the clicked world location, clamped into the safe area, and closes after an action or Escape. |
| Top center | Short-lived toast | Use for a single meaningful event. Queue at most three and expire them quickly. Never use it for ambient status. |

For the RuneScape-style version, the top-right is a single control cluster rather than three unrelated widgets: minimap and compass first, HP/prayer/run orbs immediately beside it, then the tab rail below. The player should be able to reach inventory, prayer, magic, skills, quests and social surfaces without searching the whole screen. The bottom-left chat dock is similarly persistent but quiet, with familiar General, Game and Private channels. The bottom-center action bar is the modern addition: it expands RuneScape’s stable hotkey and combat-style grammar without changing the positions of the classic navigation controls.

## What is always visible

The exploration state should contain only four ideas: where the player is, where they are going, how healthy and mobile they are, and what actions are immediately available.

For this project, “always on” should feel closer to RuneScape than to a generic MMO: top-right minimap/orbs/tabs, bottom-left chat, and bottom-center action bar. Those three regions are stable muscle memory. The rest of the atlas remains contextual.

The bottom-center HUD is therefore the persistent core. It should be compact enough to leave the lower third of the game view open. Health is red, prayer or faith is blue, run energy is green, and the special resource is gold. These colors should not be reused for unrelated statuses. The action slots keep stable positions and stable keys; a player should not have to relearn them in a bank, dungeon, or town.

The minimap and objective tracker form one navigation group. The tracker should not become a second quest journal. Its job is to answer “what should I do next?” The full journal answers “what are all my quests and why do they matter?”

Chat has meaning when it asks for attention. A collapsed bar is enough while the player is moving. Opening it grows upward from the bottom-left so it does not cover the action bar or the route ahead.

## State transitions

### Exploration

Show the compact bottom-center HUD, minimap, active objective tracker, and collapsed chat. Hide every atlas window. When the player enters a named location, show a small location toast once, then let it fade.

### Combat

Keep the exploration anchors in place. Add a target frame near the upper center and a small number of target status effects beside it. Keep the objective tracker unless the encounter itself is the objective; in that case update the existing tracker instead of adding another panel. Do not show damage numbers continuously. Reserve them for confirmed hits, critical events, or accessibility settings.

### World interaction

When the player opens a bank, shop, trade, or dialogue, hide the combat HUD and dim the world. Show one interaction window. A bank may combine backpack and vault into one window because they are two sides of the same decision; equipment and talents should not appear beside it. Close with Escape, the close button, or a completed interaction.

The bank should feel like an extension of the right-side inventory tab, not a detached MMO modal. Keep the minimap/orbs available as orientation, collapse chat to its title bar, and let the bank own the action focus. The `rs_hybrid_bank.png` concept shows this relationship.

### Full-screen knowledge

The map, quest journal, codex, talents, settings, social roster and profile are deliberate destinations. Open them as a single centered or near-full-screen task surface with a clear title, one primary navigation rail, and one close route. The player should always know which surface is open and how to return to play.

### Context actions

Right-clicking or long-pressing an actor or world object opens a small context menu next to the target. It should contain only actions valid for that target. A context menu is not a general navigation menu; use the top-level map, journal and settings surfaces for that.

## Input and accessibility rules

- `Escape` closes the topmost surface first, then returns to gameplay.
- The same key or button opens a surface and closes it again.
- Focus moves into the active surface, and controller navigation never jumps behind a modal.
- All important actions have a text label or tooltip; icon-only actions are limited to familiar controls such as close, search, and map zoom.
- Keep a minimum 40 px pointer target on desktop and a larger target mode for controller or touch layouts.
- Do not put critical text over bright world geometry without a translucent backing plate.
- Never use animation to move a persistent control to a new location. Animate opacity, scale, or a short contextual reveal in its existing anchor.

## Recommended implementation order

1. Replace the current always-on combat shell with the compact bottom-center exploration HUD from `exploration_always_on.png`.
2. Move minimap and objective tracking into the top-right navigation group.
3. Make chat collapsed by default and expand it only on focus or message attention.
4. Add the target frame and combat-only status strip from `combat_focused.png`.
5. Make bank, shop, trade, inventory and equipment mutually exclusive interaction surfaces, using the dimmed-world behavior shown in `interaction_bank.png`.
6. Add the full-screen map, journal, codex, talents, settings and social surfaces after the navigation and input contract is stable.

## RuneScape hybrid decisions

Keep OSRS mechanics legible: right-click context actions, familiar tab locations, explicit prayer and run state, stable hotkeys, readable item quantities, and clear combat-style choices. Modernize the presentation around those rules: larger hit targets, controller focus, responsive safe areas, high-contrast text backing, short state transitions, and a compact action bar. Do not modernize by moving familiar controls into novel locations or by replacing explicit menus with ambiguous radial gestures.

The atlas files already provide the visual language and native scenes. This placement pass defines when each one is allowed to appear, which keeps the player’s attention on the game instead of on the interface.
