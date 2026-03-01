extends CanvasLayer
class_name HotkeyHint

@export var margin_right: float = 16.0
@export var margin_bottom: float = 16.0
@export var collapsed_size: float = 38.0
@export var expanded_width: float = 420.0
@export var expanded_height: float = 236.0
@export var expand_duration: float = 0.14

var _panel: PanelContainer
var _header_row: HBoxContainer
var _title_label: Label
var _details: VBoxContainer
var _expand_tween: Tween
var _expanded: bool = false
var _current_size: Vector2 = Vector2.ZERO

func _ready() -> void:
	_build_ui()
	_set_expanded(false, true)

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "HotkeysPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_panel.clip_contents = true
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	_header_row = HBoxContainer.new()
	_header_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_header_row.add_theme_constant_override("separation", 8)
	content.add_child(_header_row)

	var icon := Label.new()
	icon.text = "?"
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon.custom_minimum_size = Vector2(16.0, 16.0)
	icon.add_theme_font_size_override("font_size", 18)
	_header_row.add_child(icon)

	_title_label = Label.new()
	_title_label.text = "Hotkeys"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title_label.add_theme_font_size_override("font_size", 14)
	_header_row.add_child(_title_label)

	var separator := HSeparator.new()
	content.add_child(separator)

	_details = VBoxContainer.new()
	_details.add_theme_constant_override("separation", 3)
	content.add_child(_details)

	_add_hotkey_row("Mouse Wheel", "Zoom camera")
	_add_hotkey_row("Middle Mouse Drag", "Pan camera")
	_add_hotkey_row("N", "New slice")
	_add_hotkey_row("R", "Rebuild terrain")
	_add_hotkey_row("Y", "Regenerate forests")
	_add_hotkey_row("B", "Regenerate boulders")
	_add_hotkey_row("Shift + R", "Randomize terrain settings")

	_panel.mouse_entered.connect(func() -> void:
		_set_expanded(true)
	)
	_panel.mouse_exited.connect(func() -> void:
		_set_expanded(false)
	)

func _add_hotkey_row(key_text: String, action_text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var key_label := Label.new()
	key_label.text = key_text
	key_label.custom_minimum_size = Vector2(166.0, 0.0)
	key_label.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0, 1.0))
	row.add_child(key_label)

	var action_label := Label.new()
	action_label.text = action_text
	action_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.9, 1.0))
	row.add_child(action_label)

	_details.add_child(row)

func _set_expanded(expand: bool, immediate: bool = false) -> void:
	if _expanded == expand and not immediate:
		return
	_expanded = expand

	if _expand_tween != null:
		_expand_tween.kill()
		_expand_tween = null

	if expand:
		_title_label.visible = true
		_details.visible = true
		_header_row.alignment = BoxContainer.ALIGNMENT_BEGIN

	var target_size := (
		Vector2(expanded_width, expanded_height)
		if expand
		else Vector2(collapsed_size, collapsed_size)
	)

	if immediate:
		_apply_panel_size(target_size)
	else:
		var from_size := _current_size
		_expand_tween = create_tween()
		_expand_tween.tween_method(_apply_panel_size, from_size, target_size, max(0.01, expand_duration))
		if not expand:
			_expand_tween.finished.connect(func() -> void:
				if _expanded:
					return
				_title_label.visible = false
				_details.visible = false
				_header_row.alignment = BoxContainer.ALIGNMENT_CENTER
				_expand_tween = null
			, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)
		else:
			_expand_tween.finished.connect(func() -> void:
				_expand_tween = null
			, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

	if immediate and not expand:
		_title_label.visible = false
		_details.visible = false
		_header_row.alignment = BoxContainer.ALIGNMENT_CENTER

func _apply_panel_size(size: Vector2) -> void:
	_current_size = size
	_panel.offset_left = -margin_right - size.x
	_panel.offset_top = -margin_bottom - size.y
	_panel.offset_right = -margin_right
	_panel.offset_bottom = -margin_bottom
