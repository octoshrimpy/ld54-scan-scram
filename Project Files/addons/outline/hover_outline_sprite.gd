extends Node2D
class_name HoverOutlineSprite

signal outline_clicked(metadata: Dictionary)

## Displays a baked sprite plus an optional outline that only appears while hovered.
## Used by tree and boulder generators so we do not keep per-piece Sprite2Ds around.

var hover_only: bool = true
var hover_margin_px: float = 0.0
var hover_alpha_threshold: float = 0.5

var _hover_bounds_local: Rect2 = Rect2()
var _local_rect: Rect2 = Rect2()
var _outline_available: bool = false
var _hover_state: bool = false
var _base_image: Image
var _metadata: Dictionary = {}

var _outline_sprite: Sprite2D
var _base_sprite: Sprite2D

func _init() -> void:
	_outline_sprite = Sprite2D.new()
	_outline_sprite.centered = false
	_outline_sprite.z_index = -1
	add_child(_outline_sprite)

	_base_sprite = Sprite2D.new()
	_base_sprite.centered = false
	add_child(_base_sprite)

func configure(
	base_texture: Texture2D,
	outline_texture: Texture2D,
	local_rect: Rect2,
	hover_margin: float,
	hover_only_mode: bool,
	alpha_threshold: float,
	metadata: Dictionary = {},
	local_sample: Image = null
) -> void:
	hover_margin_px = max(0.0, hover_margin)
	hover_only = hover_only_mode
	hover_alpha_threshold = clampf(alpha_threshold, 0.0, 1.0)
	_outline_available = outline_texture != null
	_local_rect = local_rect
	_base_image = local_sample
	_metadata = metadata.duplicate(true) if not metadata.is_empty() else {}

	_base_sprite.texture = base_texture
	_base_sprite.centered = false

	_outline_sprite.texture = outline_texture
	_outline_sprite.centered = false
	_outline_sprite.visible = _outline_available and not hover_only

	var margin_vec := Vector2(hover_margin_px, hover_margin_px)
	_hover_bounds_local = Rect2(
		_local_rect.position - margin_vec,
		_local_rect.size + margin_vec * 2.0
	)

	_hover_state = false
	set_process(_outline_available and hover_only)
	set_process_unhandled_input(true)

func _ready() -> void:
	set_process_unhandled_input(true)

func _process(_delta: float) -> void:
	if not _outline_available or not hover_only:
		return
	var hovered := _cursor_hits_sprite()
	if hovered == _hover_state:
		return
	_hover_state = hovered
	_outline_sprite.visible = hovered

func _cursor_hits_sprite() -> bool:
	var mouse_pos := get_global_mouse_position()
	var rect_global := Rect2(
		global_position + _hover_bounds_local.position,
		_hover_bounds_local.size
	)
	if not rect_global.has_point(mouse_pos):
		return false
	var local_point := mouse_pos - global_position
	if not _local_rect.has_point(local_point):
		return false
	if _base_image == null:
		return true
	var px := int(floor(local_point.x - _local_rect.position.x))
	var py := int(floor(local_point.y - _local_rect.position.y))
	if px < 0 or py < 0 or px >= _base_image.get_width() or py >= _base_image.get_height():
		return false
	var alpha := _base_image.get_pixel(px, py).a
	return alpha >= hover_alpha_threshold

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed or mb.is_echo():
		return
	if _cursor_hits_sprite():
		emit_signal("outline_clicked", _metadata)

func show_outline_immediate(show: bool) -> void:
	if not _outline_available:
		return
	hover_only = false
	set_process(false)
	_outline_sprite.visible = show
