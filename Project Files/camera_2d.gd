# Camera2D.gd
extends Camera2D
@export var min_zoom := 0.4
@export var max_zoom := 10.0
@export var step := 0.1
var dragging := false
var last_screen := Vector2.ZERO

func _ready() -> void:
	make_current()
	_zoom_at_cursor(3.0)  # initial zoom

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.pressed:
			match e.button_index:
				MOUSE_BUTTON_WHEEL_UP:   _zoom_at_cursor(1.0 + step)
				MOUSE_BUTTON_WHEEL_DOWN: _zoom_at_cursor(1.0 - step)
				MOUSE_BUTTON_MIDDLE:
					dragging = true
					last_screen = get_viewport().get_mouse_position()
		else:
			if e.button_index == MOUSE_BUTTON_MIDDLE:
				dragging = false
	elif e is InputEventMouseMotion and dragging:
		var cur := get_viewport().get_mouse_position()
		# convert screen delta to world delta by zoom
		global_position -= (cur - last_screen) * (1.0 / zoom.x)
		last_screen = cur

func _zoom_at_cursor(factor: float) -> void:
	var pre := get_global_mouse_position()  # world point under cursor
	var z := clampf(zoom.x * factor, min_zoom, max_zoom)
	zoom = Vector2(z, z)
	var post := get_global_mouse_position()
	# shift so the same world point stays under cursor
	global_position += pre - post
