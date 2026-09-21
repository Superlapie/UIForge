extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := "res://.aether/test/combat_hud_1280.png"
	var image := Image.new()
	var load_error := image.load(path)
	if load_error != OK:
		print(JSON.stringify({"success": false, "failed": 1, "code": "RENDER_IMAGE_LOAD_FAILED", "path": path}))
		quit(1)
		return
	var colored_samples := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			var sample := image.get_pixel(x, y)
			if sample.r + sample.g + sample.b > 0.08:
				colored_samples += 1
	var success := colored_samples >= 24
	print(JSON.stringify({
		"success": success,
		"failed": 0 if success else 1,
		"colored_samples": colored_samples,
		"viewport": {"width": image.get_width(), "height": image.get_height()}
	}))
	quit(0 if success else 1)
