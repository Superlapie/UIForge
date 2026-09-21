# Game integration

Generated scenes are normal Godot scenes. The tool does not generate gameplay or server code.

Assume `examples/scenes/inventory.tscn` was built from `examples/specs/inventory.ui.json`.

## GDScript

```gdscript
extends Control

const AetherRuntime = preload("res://addons/aether_ui/core/aether_runtime.gd")
const INVENTORY_SCENE = preload("res://examples/scenes/inventory.tscn")

func open_inventory() -> void:
	var inventory := INVENTORY_SCENE.instantiate()
	$UI.add_child(inventory)
	AetherRuntime.connect_action(inventory, "inventory_close", _on_inventory_close)
	AetherRuntime.set_text(inventory, "inventory_capacity", "23 / 28 SLOTS")

func _on_inventory_close() -> void:
	var inventory := AetherRuntime.find_by_id($UI, "inventory_window")
	if inventory != null:
		inventory.queue_free()
```

The direct Godot equivalent is also stable because generated names equal IDs:

```gdscript
var withdraw_button: Button = $BankRoot/bank_window/bank_withdraw
withdraw_button.pressed.connect(_on_withdraw_pressed)
```

## C#

```csharp
using Godot;

public partial class InventoryHost : Control
{
    private readonly PackedScene InventoryScene =
        GD.Load<PackedScene>("res://examples/scenes/inventory.tscn");

    public void OpenInventory()
    {
        var inventory = InventoryScene.Instantiate<Control>();
        GetNode<Control>("UI").AddChild(inventory);

        var close = inventory.GetNode<Button>("inventory_close");
        close.Pressed += OnInventoryClose;

        var capacity = inventory.GetNode<Label>("inventory_capacity");
        capacity.Text = "23 / 28 SLOTS";
    }

    private void OnInventoryClose()
    {
        var inventory = GetNodeOrNull<Control>("UI/inventory_window");
        inventory?.QueueFree();
    }
}
```

## Combat HUD

The combat HUD is still ordinary Godot UI. Update the native progress controls and their separate display labels from game-owned state:

~~~gdscript
const HUD_SCENE = preload("res://examples/scenes/combat_hud.tscn")

func create_hud() -> Control:
	var hud := HUD_SCENE.instantiate()
	$UI.add_child(hud)
	AetherRuntime.set_value(hud, "health_bar", 0.74)
	AetherRuntime.set_text(hud, "health_label", "740 / 1000")
	AetherRuntime.connect_action(hud, "action_slot_1", _on_hotbar_1)
	return hud
~~~

~~~csharp
var hudScene = GD.Load<PackedScene>("res://examples/scenes/combat_hud.tscn");
var hud = hudScene.Instantiate<Control>();
GetNode<Control>("UI").AddChild(hud);
hud.GetNode<ProgressBar>("health_bar").Value = 0.74;
hud.GetNode<Label>("health_label").Text = "740 / 1000";
hud.GetNode<Button>("action_slot_1").Pressed += OnHotbar1;
~~~

The authored preview ratios are visual-only. Replace them immediately from client state; the document contains no combat or server authority.

## Bindings and actions

The source document's `binding` and `action` values become `metadata/aether_binding` and `metadata/aether_action`. They are identifiers, not scripts. The game may map them to its own event bus, controller, or C# services.

Lightweight motion is likewise data-only. A node’s `transitions` map becomes `metadata/aether_transitions`; a UI controller can read it with `AetherRuntime.transition_config(node)` and call `AetherRuntime.play_transition(control, "panel_reveal")`. This helper is optional and does not add gameplay logic to generated scenes.

Effect references are data-only as well: `effects` becomes `metadata/aether_effects`, and `AetherRuntime.effect_config(node)` exposes the decoded name/object/array to a game-owned visual controller. Project-owned materials remain ordinary Godot resources.

For repeated data such as inventory slots, keep the generated layout and style, then populate the ordinary generated children or use a game-owned controller. Do not add MMO networking logic to the document compiler.
