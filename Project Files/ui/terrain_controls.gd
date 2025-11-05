extends CanvasLayer
class_name TerrainControls

@export var map_path: NodePath
@export var trees_path: NodePath
@export var boulders_path: NodePath
@export var reseed_world_on_change: bool = false

@onready var height_freq_slider: HSlider = %HeightFreqSlider
@onready var height_freq_value: Label = %HeightFreqValue
@onready var height_octaves_slider: HSlider = %HeightOctavesSlider
@onready var height_octaves_value: Label = %HeightOctavesValue
@onready var height_gain_slider: HSlider = %HeightGainSlider
@onready var height_gain_value: Label = %HeightGainValue
@onready var height_lacun_slider: HSlider = %HeightLacunSlider
@onready var height_lacun_value: Label = %HeightLacunValue
@onready var detail_freq_slider: HSlider = %DetailFreqSlider
@onready var detail_freq_value: Label = %DetailFreqValue
@onready var detail_weight_slider: HSlider = %DetailWeightSlider
@onready var detail_weight_value: Label = %DetailWeightValue
@onready var height_min_slider: HSlider = %HeightMinSlider
@onready var height_min_value: Label = %HeightMinValue
@onready var height_max_slider: HSlider = %HeightMaxSlider
@onready var height_max_value: Label = %HeightMaxValue
@onready var height_shape_slider: HSlider = %HeightShapeSlider
@onready var height_shape_value: Label = %HeightShapeValue

var _map: Node
var _trees: Node
var _boulders: Node
var _updating := false
var _last_slider: HSlider
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_map = (get_node_or_null(map_path) if not map_path.is_empty() else null)
	_trees = (get_node_or_null(trees_path) if not trees_path.is_empty() else null)
	_boulders = (get_node_or_null(boulders_path) if not boulders_path.is_empty() else null)
	for slider in _all_sliders():
		slider.value_changed.connect(_on_slider_value_changed.bind(slider))
	_sync_from_map()

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_R and e.shift_pressed:
		_randomize_settings()

func _on_slider_value_changed(_value: float, slider: HSlider) -> void:
	if _updating:
		return
	_last_slider = slider
	_apply_settings()

func _apply_settings() -> void:
	_enforce_min_max_gap()
	if _map == null or not _map.has_method("apply_height_settings"):
		return
	var settings := {
		"height_freq": height_freq_slider.value,
		"height_octaves": int(round(height_octaves_slider.value)),
		"height_gain": height_gain_slider.value,
		"height_lacun": height_lacun_slider.value,
		"height_detail_freq_mult": detail_freq_slider.value,
		"height_detail_weight": detail_weight_slider.value,
		"height_min_t": height_min_slider.value,
		"height_max_t": height_max_slider.value,
		"height_shape_exp": height_shape_slider.value,
	}
	_map.apply_height_settings(settings, reseed_world_on_change)
	_refresh_world()
	_sync_from_map()

func _refresh_world() -> void:
	if _trees != null and _trees.has_method("regenerate_forest"):
		_trees.call("regenerate_forest")
	if _boulders != null and _boulders.has_method("regenerate_boulders"):
		_boulders.call("regenerate_boulders", reseed_world_on_change)

func _sync_from_map() -> void:
	if _map == null or not _map.has_method("get_height_settings"):
		return
	var settings: Dictionary = _map.call("get_height_settings")
	_updating = true
	height_freq_slider.value = settings.get("height_freq", height_freq_slider.value)
	height_octaves_slider.value = settings.get("height_octaves", height_octaves_slider.value)
	height_gain_slider.value = settings.get("height_gain", height_gain_slider.value)
	height_lacun_slider.value = settings.get("height_lacun", height_lacun_slider.value)
	detail_freq_slider.value = settings.get("height_detail_freq_mult", detail_freq_slider.value)
	detail_weight_slider.value = settings.get("height_detail_weight", detail_weight_slider.value)
	height_min_slider.value = settings.get("height_min_t", height_min_slider.value)
	height_max_slider.value = settings.get("height_max_t", height_max_slider.value)
	height_shape_slider.value = settings.get("height_shape_exp", height_shape_slider.value)
	_updating = false
	_update_value_labels()

func _enforce_min_max_gap() -> void:
	var min_val := height_min_slider.value
	var max_val := height_max_slider.value
	if min_val <= max_val - 0.01:
		return
	var prev := _updating
	_updating = true
	if _last_slider == height_min_slider:
		height_max_slider.value = clamp(min_val + 0.01, height_max_slider.min_value, height_max_slider.max_value)
	else:
		height_min_slider.value = clamp(max_val - 0.01, height_min_slider.min_value, height_min_slider.max_value)
	_updating = prev

func _update_value_labels() -> void:
	height_freq_value.text = _format_float(height_freq_slider.value, 3)
	height_octaves_value.text = str(int(round(height_octaves_slider.value)))
	height_gain_value.text = _format_float(height_gain_slider.value, 2)
	height_lacun_value.text = _format_float(height_lacun_slider.value, 2)
	detail_freq_value.text = _format_float(detail_freq_slider.value, 2)
	detail_weight_value.text = _format_float(detail_weight_slider.value, 2)
	height_min_value.text = _format_float(height_min_slider.value, 2)
	height_max_value.text = _format_float(height_max_slider.value, 2)
	height_shape_value.text = _format_float(height_shape_slider.value, 2)

func _all_sliders() -> Array[HSlider]:
	return [
		height_freq_slider,
		height_octaves_slider,
		height_gain_slider,
		height_lacun_slider,
		detail_freq_slider,
		detail_weight_slider,
		height_min_slider,
		height_max_slider,
		height_shape_slider,
	]

func _format_float(value: float, digits: int) -> String:
	return ("%0." + str(clampi(digits, 0, 6)) + "f") % value

func _randomize_settings() -> void:
	_rng.randomize()
	_updating = true
	height_freq_slider.value = _rng.randf_range(height_freq_slider.min_value, height_freq_slider.max_value)
	height_lacun_slider.value = _rng.randf_range(height_lacun_slider.min_value, height_lacun_slider.max_value)
	_updating = false
	_apply_settings()
