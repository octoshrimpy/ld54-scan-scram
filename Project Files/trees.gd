# trees.gd — TreeGen: groves → trees (trunk/branches/leaves) with per-tree outline bake
# Godot 4.5.x
class_name TreeGen
extends Node2D

signal highlight_clicked(cell: Vector2i, world_position: Vector2, source: StringName)

const TreeOutlineFactoryScript := preload("res://addons/outline/TreeOutlineFactory.gd")
const MapUtilsRef := preload("res://utils/map_utils.gd")
const TREE_SOURCE := &"trees"

enum CellClass {
	LAND,
	SHORE_LAND,
	SHORE_WATER,
	WATER
}

const CELL_CLASS_NAMES := {
	"land": CellClass.LAND,
	"shore_land": CellClass.SHORE_LAND,
	"shore_water": CellClass.SHORE_WATER,
	"water": CellClass.WATER
}

# ───────────────────────────────── Scene/atlas refs ───────────────────────────
@export var atlas_layer: TileMapLayer
@export var trunks_root: Node2D
@export var map_ref: NodePath

# ─────────────────────────── World/grid size (cells) ──────────────────────────
@export var W: int = 20
@export var H: int = 20
@export var SOURCE_ID: int = 0

# ───────────────────────────── Outline controls ──────────────────────────────
@export var outline_color: Color = Color(0.08, 0.78, 0.52, 0.85)
@export_range(0, 8, 1) var outline_thickness_px: int = 1
@export_range(0, 16, 1) var outline_padding_px: int = 3
@export var outline_hover_margin_px: float = 0.0
@export var outlines_hover_only: bool = true
@export_range(0.0, 1.0, 0.01) var outline_hover_alpha_threshold: float = 0.65

# ─────────────────────────── GROVE DISTRIBUTION ───────────────────────────────
@export var grove_count_min: int = 3
@export var grove_count_max: int = 6
@export var grove_spacing_cells: int = 6
@export var grove_radius_cells_min: int = 2
@export var grove_radius_cells_max: int = 5
@export var trees_per_grove_min: int = 2
@export var trees_per_grove_max: int = 6
@export var spawn_margin_cells: int = 1
@export var slope_max: int = 1
@export var max_spawn_attempts: int = 300
@export var micro_spawn_attempts: int = 20
@export var footprint_half_width_cells: int = 1
@export var require_grass_top: bool = false
@export var allow_relaxed_retry: bool = true
@export var shoreline_tree_target: int = 6
@export var shoreline_spawn_attempts: int = 24

# ───────────────────────── Bark / Leaf asset pools ────────────────────────────
@export var bark_x_range: Vector2i = Vector2i(64, 67)
@export var bark_y_range: Vector2i = Vector2i(56, 64)

# Leaf tiles area; we later pick ONE tile and ONE 2x2 subtile per grove
@export var leaf_ranges: Array[Rect2i] = [Rect2i(Vector2i(56,56), Vector2i(1, 5))]
@export var leaf_subtile_cols: int = 2
@export var leaf_subtile_rows: int = 2

# ───────────────────────── Trunk construction params ──────────────────────────
@export var trunk_total_px_min: int = 44
@export var trunk_total_px_max: int = 60
@export var trunk_width_px_min: int = 3
@export var trunk_width_px_max: int = 6
@export var wiggle_prob: float = 0.30
@export var wiggle_bias: float = 0.0
@export var max_lateral_px: int = 10

# ───────────────────────── Branch shape / overlap ─────────────────────────────
@export var branch_width_px: int = 3
@export var branch_step_h_px: Vector2i = Vector2i(2, 3)
@export var branch_shift_px: int = 1
@export var branch_dev_px: int = 1
@export var branch_thickness_taper: int = 1
@export var branch_min_width_px: int = 2
@export var branch_vertical_overlap_px: int = 1
@export var branch_attach_min_px: int = 1
@export var branch_base_inset_px: int = 1

# ───────────────────────── Branch layout randomness ───────────────────────────
@export var branch_count_min: int = 3
@export var branch_count_max: int = 7
@export var branch_length_min_px: int = 9
@export var branch_length_max_px: int = 18
@export var branch_min_gap_px: int = 6
@export var branch_zone_min: float = 0.20
@export var branch_zone_max: float = 0.90
@export_range(-1.0, 1.0, 0.01) var branch_side_bias: float = 0.0
@export var branch_alternate_sides: bool = true

# ───────────────────────────── Foliage params ────────────────────────────────
@export var leaves_z_offset: int = 3
@export var segments_z_offset: int = 2
@export var branch_z_offset: int = 2

@export var leaves_filter: CanvasItem.TextureFilter = CanvasItem.TEXTURE_FILTER_NEAREST
@export var segment_filter: CanvasItem.TextureFilter = CanvasItem.TEXTURE_FILTER_NEAREST

@export var leaf_tip_count_min: int = 2
@export var leaf_tip_count_max: int = 3
@export var leaf_tip_radius_px: int = 5
@export var leaf_tip_offset_up_px: int = 1

@export var leaf_single_on_branch_chance: float = 0.45
@export var leaf_single_offset_radius_px: int = 3

@export var leaf_crown_count_min: int = 10
@export var leaf_crown_count_max: int = 26
@export var leaf_crown_radius_px: int = 6
@export var leaf_crown_offset_up_px: int = 2

# ── Connectivity controls (no floating clumps) ────────────────────────────────
@export var leaf_connect_attempts: int = 24
@export var leaf_min_overlap_px: int = 2
@export var leaf_snap_extra_px: int = 1

const TREE_SPECIES: Array[Dictionary] = [
	{
		"id": "evergreen",
		"label": "Evergreen Fir",
		"biome": "land",
		"spawn_profile": {
			"allow_water": false,
			"require_water": false,
			"require_grass": true,
			"preferred_classes": ["land", "shore_land"],
			"weight": 1.0
		},
		"overrides": {
			"trunk_total_px_min": 60,
			"trunk_total_px_max": 84,
			"trunk_width_px_min": 3,
			"trunk_width_px_max": 5,
			"branch_count_min": 4,
			"branch_count_max": 6,
			"branch_length_min_px": 8,
			"branch_length_max_px": 14,
			"branch_zone_min": 0.40,
			"branch_zone_max": 0.95,
			"branch_shift_px": 1,
			"branch_dev_px": 1,
			"branch_step_h_px": Vector2i(2, 3),
			"branch_thickness_taper": 2,
			"leaf_crown_radius_px": 4,
			"leaf_crown_count_min": 10,
			"leaf_crown_count_max": 18,
			"leaf_single_on_branch_chance": 0.18,
			"leaf_tip_count_min": 1,
			"leaf_tip_count_max": 2,
			"leaf_tip_radius_px": 4,
			"leaf_tip_offset_up_px": 2,
			"wiggle_prob": 0.18,
			"max_lateral_px": 8
		}
	},
	{
		"id": "acacia",
		"label": "Acacia Umbra",
		"biome": "land",
		"spawn_profile": {
			"allow_water": false,
			"require_water": false,
			"require_grass": true,
			"preferred_classes": ["land", "shore_land"],
			"weight": 1.0
		},
		"overrides": {
			"trunk_total_px_min": 44,
			"trunk_total_px_max": 58,
			"trunk_width_px_min": 4,
			"trunk_width_px_max": 7,
			"branch_count_min": 5,
			"branch_count_max": 9,
			"branch_length_min_px": 13,
			"branch_length_max_px": 22,
			"branch_zone_min": 0.15,
			"branch_zone_max": 0.55,
			"branch_shift_px": 2,
			"branch_dev_px": 2,
			"branch_step_h_px": Vector2i(3, 4),
			"branch_thickness_taper": 1,
			"leaf_crown_radius_px": 8,
			"leaf_crown_count_min": 14,
			"leaf_crown_count_max": 28,
			"leaf_crown_offset_up_px": 1,
			"leaf_single_on_branch_chance": 0.60,
			"leaf_single_offset_radius_px": 4,
			"leaf_tip_count_min": 2,
			"leaf_tip_count_max": 3,
			"leaf_tip_radius_px": 6,
			"leaf_tip_offset_up_px": 1,
			"wiggle_prob": 0.32,
			"max_lateral_px": 14
		}
	},
	{
		"id": "mangrove",
		"label": "Mangrove Lantern",
		"biome": "water",
		"spawn_profile": {
			"allow_water": false,
			"require_water": true,
			"avoid_water_radius": 0,
			"require_grass": false,
			"prefer_shore": true,
			"preferred_classes": ["shore_land"],
			"allowed_classes": ["shore_land"],
			"shore_only": true,
			"micro_attempts": 32,
			"spawn_margin_cells": 0,
			"slope_allow": 4,
			"weight": 1.35
		},
		"overrides": {
			"trunk_total_px_min": 36,
			"trunk_total_px_max": 52,
			"trunk_width_px_min": 3,
			"trunk_width_px_max": 5,
			"branch_count_min": 4,
			"branch_count_max": 7,
			"branch_length_min_px": 10,
			"branch_length_max_px": 18,
			"branch_zone_min": 0.30,
			"branch_zone_max": 0.85,
			"branch_shift_px": 2,
			"branch_dev_px": 3,
			"branch_step_h_px": Vector2i(2, 4),
			"branch_thickness_taper": 1,
			"leaf_crown_radius_px": 6,
			"leaf_crown_count_min": 12,
			"leaf_crown_count_max": 24,
			"leaf_crown_offset_up_px": 3,
			"leaf_single_on_branch_chance": 0.40,
			"leaf_tip_count_min": 2,
			"leaf_tip_count_max": 3,
			"leaf_tip_radius_px": 5,
			"leaf_tip_offset_up_px": 2,
			"footprint_half_width_cells": 2,
			"wiggle_prob": 0.28,
			"max_lateral_px": 12,
			"require_grass_top": false
		}
	}
]

var _rng := RandomNumberGenerator.new()

const SPECIES_PROPERTY_KEYS := [
	"trunk_total_px_min",
	"trunk_total_px_max",
	"trunk_width_px_min",
	"trunk_width_px_max",
	"branch_count_min",
	"branch_count_max",
	"branch_length_min_px",
	"branch_length_max_px",
	"branch_zone_min",
	"branch_zone_max",
	"branch_shift_px",
	"branch_dev_px",
	"branch_step_h_px",
	"branch_thickness_taper",
	"branch_min_width_px",
	"branch_vertical_overlap_px",
	"branch_attach_min_px",
	"max_lateral_px",
	"wiggle_prob",
	"wiggle_bias",
	"leaf_single_on_branch_chance",
	"leaf_single_offset_radius_px",
	"leaf_tip_count_min",
	"leaf_tip_count_max",
	"leaf_tip_radius_px",
	"leaf_tip_offset_up_px",
	"leaf_crown_count_min",
	"leaf_crown_count_max",
	"leaf_crown_radius_px",
	"leaf_crown_offset_up_px",
	"footprint_half_width_cells",
	"require_grass_top"
]

const DEFAULT_SPECIES_ID := "evergreen"
const WiggleShader := preload("res://shaders/iso_wiggle.gdshader")

# ─────────────────────────── Internal caches / state ─────────────────────────
var _atlas_src: TileSetAtlasSource
var _atlas_tex: Texture2D
var _atlas_image: Image
var _bark_outline_cache: Dictionary = {}

# per-tree (mutates as we build each tree)
var _trunk_total_px: int = 48
var _trunk_width_px: int = 5
var _map_cache: Node
var _base_species_config: Dictionary = {}
var _current_species_id: String = DEFAULT_SPECIES_ID
var _cell_class_map: PackedInt32Array = PackedInt32Array()
var _land_cells: Array[Vector2i] = []
var _shoreline_land_cells: Array[Vector2i] = []
var _shoreline_water_cells: Array[Vector2i] = []
var _water_cells: Array[Vector2i] = []
var _leaf_wiggle_material: ShaderMaterial
var _outline_factory: TreeOutlineFactory
var _occupied_cells: Array[Vector2i] = []

# helper records
class GroundSpawn:
	var position: Vector2 = Vector2.ZERO
	var cell: Vector2i = Vector2i.ZERO
	var z: int = 0

class Grove:
	var center_cell: Vector2i
	var center_world: Vector2
	var z: int
	var bark_region: Rect2i
	var leaf_region: Rect2i
	var radius_cells: int
	var tree_count: int

# ───────────────────────────── Lifecycle ──────────────────────────────────────
func _ready() -> void:
	_rng.randomize()
	if trunks_root == null:
		trunks_root = self
	_map_cache = _resolve_map()
	_cache_base_species_config()
	_setup_leaf_material()
	_outline_factory = TreeOutlineFactoryScript.new()
	_regenerate_forest()

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_Y: _regenerate_forest()

func _cache_base_species_config() -> void:
	if not _base_species_config.is_empty():
		return
	for key in SPECIES_PROPERTY_KEYS:
		_base_species_config[key] = get(key)

func _restore_base_species_config() -> void:
	if _base_species_config.is_empty():
		return
	for key in _base_species_config.keys():
		set(key, _base_species_config[key])

func _setup_leaf_material() -> void:
	if WiggleShader == null:
		return
	_leaf_wiggle_material = ShaderMaterial.new()
	_leaf_wiggle_material.shader = WiggleShader
	_leaf_wiggle_material.set_shader_parameter("axis", Vector2(0.55, -0.35))
	_leaf_wiggle_material.set_shader_parameter("amplitude_px", 0.95)
	_leaf_wiggle_material.set_shader_parameter("frequency", 3.1)
	_leaf_wiggle_material.set_shader_parameter("speed", 0.85)
	_leaf_wiggle_material.set_shader_parameter("noise_mix", 0.4)
	_leaf_wiggle_material.set_shader_parameter("world_phase_scale", Vector2(0.03, 0.03))
	_leaf_wiggle_material.set_shader_parameter("base_phase", 0.65)
	var wind_dir := Vector2(_randf_range(-1.0, 1.0), _randf_range(-1.0, 1.0))
	if wind_dir.length_squared() < 0.0001:
		wind_dir = Vector2(0.7, 0.2)
	else:
		wind_dir = wind_dir.normalized()
	_leaf_wiggle_material.set_shader_parameter("wind_noise_scale", Vector2(0.006, 0.01))
	_leaf_wiggle_material.set_shader_parameter(
		"wind_noise_offset",
		Vector2(_randf_range(-500.0, 500.0), _randf_range(-500.0, 500.0))
	)
	_leaf_wiggle_material.set_shader_parameter("wind_scroll_dir", wind_dir)
	_leaf_wiggle_material.set_shader_parameter("wind_scroll_speed", _randf_range(0.05, 0.18))
	_leaf_wiggle_material.set_shader_parameter("wind_strength", 0.6)
	_leaf_wiggle_material.set_shader_parameter("wind_min_strength", 0.12)
	_leaf_wiggle_material.set_shader_parameter("wind_axis_mix", 0.9)

func _configure_outline_factory() -> void:
	if _outline_factory == null:
		_outline_factory = TreeOutlineFactoryScript.new()
	_outline_factory.outline_color = outline_color
	_outline_factory.outline_thickness_px = outline_thickness_px
	_outline_factory.padding_px = outline_padding_px
	_outline_factory.hover_margin_px = outline_hover_margin_px
	_outline_factory.hover_only = outlines_hover_only
	_outline_factory.hover_alpha_threshold = outline_hover_alpha_threshold

func _apply_species_overrides(overrides: Dictionary) -> void:
	if overrides.is_empty():
		return
	_restore_base_species_config()
	for key in overrides.keys():
		set(key, overrides[key])

func _get_species_by_id(id: String) -> Dictionary:
	for s in TREE_SPECIES:
		if s.get("id", "") == id:
			return s
	return TREE_SPECIES[0] if TREE_SPECIES.size() > 0 else {}

func _species_footprint_radius(species: Dictionary) -> int:
	var base_fp: int = footprint_half_width_cells
	if not _base_species_config.is_empty() and _base_species_config.has("footprint_half_width_cells"):
		base_fp = int(_base_species_config.get("footprint_half_width_cells", base_fp))
	var overrides: Dictionary = species.get("overrides", {}) as Dictionary
	var fp_variant: Variant = overrides.get("footprint_half_width_cells", base_fp)
	match typeof(fp_variant):
		TYPE_INT:
			return max(0, int(fp_variant))
		TYPE_FLOAT:
			return max(0, int(round(fp_variant)))
		_:
			return max(0, base_fp)

func _has_water_within(cell: Vector2i, radius: int) -> bool:
	for dy in range(-radius, radius + 1):
		var ny := clampi(cell.y + dy, 0, H - 1)
		for dx in range(-radius, radius + 1):
			var nx := clampi(cell.x + dx, 0, W - 1)
			if _map_has_water(nx, ny):
				return true
	return false

func _has_land_within(cell: Vector2i, radius: int) -> bool:
	for dy in range(-radius, radius + 1):
		var ny := clampi(cell.y + dy, 0, H - 1)
		for dx in range(-radius, radius + 1):
			var nx := clampi(cell.x + dx, 0, W - 1)
			if not _map_has_water(nx, ny):
				if dx == 0 and dy == 0 and _map_has_water(cell.x, cell.y):
					continue
				return true
	return false

func _cell_index(x: int, y: int) -> int:
	return y * W + x

func _refresh_cell_classes() -> void:
	var total: int = W * H
	if total <= 0:
		_cell_class_map = PackedInt32Array()
		_land_cells.clear()
		_shoreline_land_cells.clear()
		_shoreline_water_cells.clear()
		_water_cells.clear()
		return

	if _cell_class_map.size() != total:
		_cell_class_map.resize(total)

	_land_cells.clear()
	_shoreline_land_cells.clear()
	_shoreline_water_cells.clear()
	_water_cells.clear()

	for y in range(H):
		for x in range(W):
			var cell := Vector2i(x, y)
			var class_id: int
			if _map_has_water(x, y):
				class_id = CellClass.WATER
				if _has_land_within(cell, 1):
					class_id = CellClass.SHORE_WATER
			elif _has_water_within(cell, 1):
				class_id = CellClass.SHORE_LAND
			else:
				class_id = CellClass.LAND

			var idx := _cell_index(x, y)
			if idx >= 0 and idx < _cell_class_map.size():
				_cell_class_map[idx] = class_id

			match class_id:
				CellClass.LAND:
					_land_cells.append(cell)
				CellClass.SHORE_LAND:
					_shoreline_land_cells.append(cell)
				CellClass.SHORE_WATER:
					_shoreline_water_cells.append(cell)
				CellClass.WATER:
					_water_cells.append(cell)

func _cell_class_at(cell: Vector2i) -> int:
	if cell.x < 0 or cell.x >= W or cell.y < 0 or cell.y >= H:
		return CellClass.LAND
	var total: int = _cell_class_map.size()
	if total != W * H or total == 0:
		return CellClass.LAND
	var idx := _cell_index(cell.x, cell.y)
	if idx < 0 or idx >= total:
		return CellClass.LAND
	return int(_cell_class_map[idx])

func _cell_class_is_waterish(class_id: int) -> bool:
	return class_id == CellClass.WATER or class_id == CellClass.SHORE_WATER

func _cell_class_from_variant(v: Variant) -> int:
	match typeof(v):
		TYPE_INT:
			return clampi(int(v), CellClass.LAND, CellClass.WATER)
		TYPE_STRING:
			var key := String(v).to_lower()
			if CELL_CLASS_NAMES.has(key):
				return int(CELL_CLASS_NAMES[key])
	return CellClass.LAND

func _int_from_variant(v: Variant, fallback: int) -> int:
	match typeof(v):
		TYPE_INT:
			return int(v)
		TYPE_FLOAT:
			return int(round(float(v)))
		_:
			return fallback

func _species_spawn_profile(species: Dictionary) -> Dictionary:
	var profile_dict := species.get("spawn_profile", {}) as Dictionary
	var biome: String = species.get("biome", "land") as String

	var allow_water: bool = bool(profile_dict.get("allow_water", biome == "water" or biome == "either"))
	var require_water: bool = bool(profile_dict.get("require_water", biome == "water"))
	var prefer_shore: bool = bool(profile_dict.get("prefer_shore", biome == "water"))
	var avoid_radius: int = _int_from_variant(profile_dict.get("avoid_water_radius", null), -1)
	var spawn_margin: int = _int_from_variant(profile_dict.get("spawn_margin_cells", null), -1)
	var micro_attempts_value: int = _int_from_variant(profile_dict.get("micro_attempts", null), micro_spawn_attempts)
	var slope_allow: int = _int_from_variant(profile_dict.get("slope_allow", null), -1)

	var require_grass_variant: Variant = profile_dict.get("require_grass", null)
	var require_grass_override: Variant = null
	if typeof(require_grass_variant) == TYPE_BOOL:
		require_grass_override = require_grass_variant

	var preferred_classes: Array[int] = []
	if profile_dict.has("preferred_classes"):
		var raw_pref: Array = profile_dict.get("preferred_classes") as Array
		if raw_pref is Array:
			for cls in raw_pref:
				preferred_classes.append(_cell_class_from_variant(cls))

	var allowed_classes: Array[int] = []
	if profile_dict.has("allowed_classes"):
		var raw_allowed: Array = profile_dict.get("allowed_classes")
		if raw_allowed is Array:
			for cls in raw_allowed:
				allowed_classes.append(_cell_class_from_variant(cls))

	var weight: float = float(profile_dict.get("weight", 1.0))

	return {
		"allow_water": allow_water,
		"require_water": require_water,
		"avoid_water_radius": max(-1, avoid_radius),
		"spawn_margin": spawn_margin,
		"micro_attempts": max(1, micro_attempts_value),
		"slope_allow": slope_allow,
		"require_grass": require_grass_override,
		"prefer_shore": prefer_shore,
		"preferred_classes": preferred_classes,
		"allowed_classes": allowed_classes,
		"weight": max(0.01, weight),
		"shore_only": bool(profile_dict.get("shore_only", false))
	}

func _class_allowed_for_profile(class_id: int, profile: Dictionary, species_biome: String) -> bool:
	var allowed_list: Array = profile.get("allowed_classes", [])
	if allowed_list.size() > 0:
		return allowed_list.has(class_id)

	match species_biome:
		"water":
			return class_id == CellClass.WATER or class_id == CellClass.SHORE_WATER or class_id == CellClass.SHORE_LAND
		"either":
			return true
		_:
			return class_id == CellClass.LAND or class_id == CellClass.SHORE_LAND

func _species_weight_for_class(class_id: int, profile: Dictionary) -> float:
	var weight: float = float(profile.get("weight", 1.0))
	if profile.get("prefer_shore", false) and (class_id == CellClass.SHORE_LAND or class_id == CellClass.SHORE_WATER):
		weight *= 1.6
	var preferred: Array = profile.get("preferred_classes", [])
	if preferred.size() > 0:
		if preferred.has(class_id):
			weight *= 1.5
		else:
			weight *= 0.8
	return max(0.01, weight)

func _pick_weighted_candidate(candidates: Array) -> Dictionary:
	if candidates.size() == 0:
		return {}
	var total_weight: float = 0.0
	for item in candidates:
		total_weight += float(item.get("weight", 1.0))
	if total_weight <= 0.0:
		return candidates[_randi_range(0, candidates.size() - 1)]
	var roll: float = _randf() * total_weight
	for item in candidates:
		roll -= float(item.get("weight", 1.0))
		if roll <= 0.0:
			return item
	return candidates.back()

func _select_species_for_cell(cell: Vector2i, biome_hint: String = "") -> Dictionary:
	if TREE_SPECIES.is_empty():
		return {}
	var class_id: int = _cell_class_at(cell)
	var candidates: Array = []

	for species in TREE_SPECIES:
		var species_biome: String = species.get("biome", "land")
		if biome_hint != "" and species_biome != biome_hint and species_biome != "either":
			continue

		var profile: Dictionary = _species_spawn_profile(species)
		if not _class_allowed_for_profile(class_id, profile, species_biome):
			continue

		var allow_water: bool = bool(profile.get("allow_water", false))
		var require_water: bool = bool(profile.get("require_water", false))
		var shore_only: bool = bool(profile.get("shore_only", false))

		if require_water and not _has_water_within(cell, 3):
			continue
		if not allow_water and _cell_class_is_waterish(class_id):
			continue

		var attempts: int = int(profile.get("micro_attempts", micro_spawn_attempts))
		var avoid_radius: int = int(profile.get("avoid_water_radius", -1))
		var footprint_override: int = _species_footprint_radius(species)
		if avoid_radius < 0:
			avoid_radius = footprint_override

		var margin_override: int = int(profile.get("spawn_margin", -1))
		var slope_override: int = int(profile.get("slope_allow", -1))
		var require_grass_override: Variant = profile.get("require_grass", null)

		var spawn: GroundSpawn = _find_nearby_ground(
			cell,
			attempts,
			allow_water,
			require_water,
			max(0, avoid_radius),
			margin_override,
			slope_override,
			require_grass_override,
			footprint_override,
			shore_only
		)

		if spawn == null and require_water:
			var expanded_allow_water: bool = allow_water and not shore_only
			spawn = _find_nearby_ground(
				cell,
				max(attempts, micro_spawn_attempts) * 2,
				expanded_allow_water,
				true,
				0,
				margin_override,
				slope_override,
				require_grass_override,
				footprint_override,
				shore_only
			)

		if spawn == null and allow_water and not shore_only and avoid_radius > 0:
			spawn = _find_nearby_ground(
				cell,
				attempts,
				true,
				require_water,
				0,
				margin_override,
				slope_override,
				require_grass_override,
				footprint_override,
				shore_only
			)

		if spawn == null:
			continue

		var weight: float = _species_weight_for_class(class_id, profile)
		candidates.append({
			"species": species,
			"spawn": spawn,
			"weight": weight
		})

	if candidates.size() > 0:
		var pick := _pick_weighted_candidate(candidates)
		return {
			"species": pick.get("species", {}),
			"spawn": pick.get("spawn", null)
		}

	if biome_hint != "":
		return {}

	var fallback_species := _get_species_by_id(DEFAULT_SPECIES_ID)
	var fallback_profile := _species_spawn_profile(fallback_species)

	var fallback_attempts: int = int(fallback_profile.get("micro_attempts", micro_spawn_attempts))
	var fallback_allow_water: bool = bool(fallback_profile.get("allow_water", false))
	var fallback_require_water: bool = bool(fallback_profile.get("require_water", false))
	var fallback_avoid: int = int(fallback_profile.get("avoid_water_radius", -1))
	var fallback_margin: int = int(fallback_profile.get("spawn_margin", -1))
	var fallback_slope: int = int(fallback_profile.get("slope_allow", -1))
	var fallback_require_grass: Variant = fallback_profile.get("require_grass", null)
	var fallback_shore_only: bool = bool(fallback_profile.get("shore_only", false))
	var fallback_footprint: int = _species_footprint_radius(fallback_species)
	if fallback_avoid < 0:
		fallback_avoid = fallback_footprint

	var fallback_spawn := _find_nearby_ground(
		cell,
		fallback_attempts,
		fallback_allow_water,
		fallback_require_water,
		max(0, fallback_avoid),
		fallback_margin,
		fallback_slope,
		fallback_require_grass,
		fallback_footprint,
		fallback_shore_only
	)
	if fallback_spawn != null:
		return {"species": fallback_species, "spawn": fallback_spawn}
	return {}

# ───────────────────────────── Forest regen ───────────────────────────────────
func regenerate_for_new_slice() -> void:
	_refresh_cell_classes()
	_regenerate_forest()

func set_seed(new_seed: int) -> void:
	_rng.seed = new_seed

func _regenerate_forest() -> void:
	# Clear previous baked sprites (and any leftovers)
	for c in trunks_root.get_children():
		if c is Sprite2D or c is Node2D:
			c.queue_free()
	_occupied_cells.clear()

	_map_cache = _resolve_map()

	# Resolve atlas
	if atlas_layer == null or atlas_layer.tile_set == null:
		push_warning("TreeGen: atlas_layer or its TileSet is null.")
		return
	_atlas_src = atlas_layer.tile_set.get_source(SOURCE_ID) as TileSetAtlasSource
	if _atlas_src == null:
		push_warning("TreeGen: TileSet source id %d is not a TileSetAtlasSource." % SOURCE_ID)
		return
	_atlas_tex = _atlas_src.texture
	if _atlas_tex == null:
		push_warning("TreeGen: Atlas source has no texture.")
		return
	_atlas_image = _atlas_tex.get_image() if _atlas_tex != null else null
	if _atlas_image != null and _atlas_image.is_compressed():
		var err := _atlas_image.decompress()
		if err != OK:
			push_warning("TreeGen: failed to decompress atlas image (%s)." % str(err))
			_atlas_image = null
	_bark_outline_cache.clear()
	_restore_base_species_config()
	_refresh_cell_classes()

	# Plan groves (strict → relaxed)
	var groves: Array[Grove] = _plan_groves(grove_spacing_cells, slope_max, require_grass_top, max_spawn_attempts)
	if groves.is_empty() and allow_relaxed_retry:
		groves = _plan_groves(max(1, int(grove_spacing_cells * 0.6)), slope_max + 2, false, int(max_spawn_attempts * 1.5))

	# Fallback grove
	if groves.is_empty():
		push_warning("TreeGen: no grove centers found; placing one at map center.")
		var fallback_species := _get_species_by_id(DEFAULT_SPECIES_ID)
		var fallback_radius := _species_footprint_radius(fallback_species)
		var gs := _fallback_center_spawn(false, false, fallback_radius)
		if gs == null:
			push_warning("TreeGen: fallback center spawn unavailable (water or invalid center).")
			return
		var g := Grove.new()
		g.center_cell = gs.cell
		g.center_world = gs.position
		g.z = gs.z
		g.radius_cells = int(float(grove_radius_cells_min + grove_radius_cells_max) / 2.0)
		g.tree_count = max(1, trees_per_grove_min)
		g.bark_region = _choose_bark_region()
		g.leaf_region = _choose_leaf_subtile_region(_choose_one_leaf_tile())
		groves.append(g)

	# Build trees
	for g in groves:
		for i in range(g.tree_count):
			var t: float = _randf() * TAU
			var r_cells: float = sqrt(_randf()) * float(g.radius_cells)
			var ox_i: int = int(round(cos(t) * r_cells))
			var oy_i: int = int(round(sin(t) * r_cells))
			var cell := Vector2i(clampi(g.center_cell.x + ox_i, 0, W - 1), clampi(g.center_cell.y + oy_i, 0, H - 1))

			var species_info: Dictionary = _select_species_for_cell(cell)
			if species_info.is_empty():
				continue
			var spawn_variant: Variant = species_info.get("spawn", null)
			if not (spawn_variant is GroundSpawn):
				continue
			var spawn: GroundSpawn = spawn_variant
			var species := species_info.get("species", {}) as Dictionary
			_apply_species_overrides(species.get("overrides", {}) as Dictionary)
			_current_species_id = species.get("id", DEFAULT_SPECIES_ID)

			_trunk_total_px = clampi(_randi_range(trunk_total_px_min, trunk_total_px_max), 4, 4096)
			_trunk_width_px = clampi(_randi_range(trunk_width_px_min, trunk_width_px_max), 1, 4096)

			_build_tree_at(spawn, g.bark_region, g.leaf_region)
			_restore_base_species_config()
	_restore_base_species_config()
	_spawn_shoreline_trees()
	_restore_base_species_config()
	_publish_obstacles()

# ─────────────────────────── Grove planning helpers ───────────────────────────
func _spawn_shoreline_trees() -> void:
	if shoreline_tree_target <= 0:
		return

	var water_species_available: bool = false
	for species in TREE_SPECIES:
		var biome: String = species.get("biome", "land")
		if biome == "water" or biome == "either":
			water_species_available = true
			break
	if not water_species_available:
		return

	var pool: Array[Vector2i] = []
	pool.append_array(_shoreline_land_cells)
	if pool.is_empty():
		return

	var want: int = clampi(shoreline_tree_target, 0, pool.size())
	if want <= 0:
		return

	var attempts: int = max(shoreline_spawn_attempts, want * 2)
	var placed: int = 0
	var tries: int = 0
	while placed < want and tries < attempts:
		tries += 1
		var cell_idx: int = _randi_range(0, pool.size() - 1)
		var cell: Vector2i = pool[cell_idx]
		var species_info: Dictionary = _select_species_for_cell(cell, "water")
		if species_info.is_empty():
			continue
		var spawn_variant: Variant = species_info.get("spawn", null)
		if not (spawn_variant is GroundSpawn):
			continue
		var spawn: GroundSpawn = spawn_variant
		var species := species_info.get("species", {}) as Dictionary
		_apply_species_overrides(species.get("overrides", {}) as Dictionary)
		_current_species_id = species.get("id", DEFAULT_SPECIES_ID)
		var bark_region := _choose_bark_region()
		var leaf_region := _choose_leaf_subtile_region(_choose_one_leaf_tile())
		_build_tree_at(spawn, bark_region, leaf_region)
		_restore_base_species_config()
		placed += 1

func _publish_obstacles() -> void:
	var map := _get_map()
	if map == null:
		return
	if not map.has_method("register_obstacle_cells"):
		return
	var payload: Array[Vector2i] = []
	for cell_variant in _occupied_cells:
		var cell: Vector2i = cell_variant
		payload.append(cell)
	map.call("register_obstacle_cells", TREE_SOURCE, payload)

func _on_hover_outline_clicked(metadata: Dictionary) -> void:
	var cell_variant: Variant = metadata.get("cell", Vector2i.ZERO)
	var world_variant: Variant = metadata.get("world", Vector2.ZERO)
	var source_variant: Variant = metadata.get("source", TREE_SOURCE)
	var cell: Vector2i = Vector2i.ZERO
	if cell_variant is Vector2i:
		cell = cell_variant
	var world: Vector2 = Vector2.ZERO
	if world_variant is Vector2:
		world = world_variant
	var source: StringName = TREE_SOURCE
	if source_variant is StringName:
		source = source_variant
	emit_signal("highlight_clicked", cell, world, source)

func _plan_groves(spacing_cells: int, slope_allow: int, grass_required: bool, attempts: int) -> Array[Grove]:
	var groves: Array[Grove] = []
	var want: int = clampi(_randi_range(grove_count_min, grove_count_max), 1, 64)
	var margin: int = clampi(spawn_margin_cells, 0, min(W, H) / 2)
	var tries: int = 0
	while groves.size() < want and tries < attempts:
		tries += 1
		var x: int = _randi_range(margin, max(margin, W - 1 - margin))
		var y: int = _randi_range(margin, max(margin, H - 1 - margin))

		var ok_space := true
		for g in groves:
			var dx := x - g.center_cell.x
			var dy := y - g.center_cell.y
			if (dx * dx + dy * dy) < spacing_cells * spacing_cells:
				ok_space = false
				break
		if not ok_space:
			continue

		var z: int = _map_surface_z(x, y)
		if z < 0:
			continue
		if _map_has_water(x, y):
			continue
		if grass_required and not _map_is_grassy(x, y, z):
			continue
		if not _is_flat_enough_custom(x, y, slope_allow):
			continue

		var pos: Vector2 = _column_bottom_world(x, y, z)

		# footprint leveling on vertical median across neighboring columns
		var halfw: int = max(0, footprint_half_width_cells)
		if halfw > 0:
			var ys: Array[float] = []
			for dx2 in range(-halfw, halfw + 1):
				var nx: int = clampi(x + dx2, 0, W - 1)
				var nz: int = _map_surface_z(nx, y)
				if nz >= 0:
					ys.append(_column_bottom_world(nx, y, nz).y)
			if ys.size() > 0:
				ys.sort()
				pos.y = floor(ys[int(float(ys.size()) / 2.0)])

		var g := Grove.new()
		g.center_cell = Vector2i(x, y)
		g.center_world = pos
		g.z = z
		g.radius_cells = clampi(_randi_range(grove_radius_cells_min, grove_radius_cells_max), 1, 64)
		g.tree_count = clampi(_randi_range(trees_per_grove_min, trees_per_grove_max), 1, 256)
		g.bark_region = _choose_bark_region()
		g.leaf_region = _choose_leaf_subtile_region(_choose_one_leaf_tile())
		if g.bark_region.size != Vector2i.ZERO and g.leaf_region.size != Vector2i.ZERO:
			groves.append(g)

	return groves

func _choose_bark_region() -> Rect2i:
	return _atlas_src.get_tile_texture_region(_choose_bark_tile())

func _choose_bark_tile() -> Vector2i:
	var bx: int = _randi_range(min(bark_x_range.x, bark_x_range.y), max(bark_x_range.x, bark_x_range.y))
	var by: int = _randi_range(min(bark_y_range.x, bark_y_range.y), max(bark_y_range.x, bark_y_range.y))
	return Vector2i(bx, by)

func _choose_one_leaf_tile() -> Vector2i:
	var pool: Array[Vector2i] = []
	for r in leaf_ranges:
		var x0: int = r.position.x
		var y0: int = r.position.y
		var w: int = max(1, r.size.x)
		var h: int = max(1, r.size.y)
		for ty in range(y0, y0 + h):
			for tx in range(x0, x0 + w):
				pool.append(Vector2i(tx, ty))
	if pool.is_empty():
		return Vector2i(56, 56)
	return pool[_randi_range(0, pool.size() - 1)]

func _choose_leaf_subtile_region(tile_xy: Vector2i) -> Rect2i:
	var full: Rect2i = _atlas_src.get_tile_texture_region(tile_xy)
	if full.size == Vector2i.ZERO:
		return full
	var cols: int = max(1, leaf_subtile_cols)
	var rows: int = max(1, leaf_subtile_rows)
	var pick: int = _randi_range(0, cols * rows - 1)
	var c_idx: int = pick % cols
	var r_idx: int = int(floor(float(pick) / float(cols)))
	var sub_w: int = max(1, int(floor(float(full.size.x) / float(cols))))
	var sub_h: int = max(1, int(floor(float(full.size.y) / float(rows))))
	return Rect2i(
		Vector2i(full.position.x + c_idx * sub_w, full.position.y + r_idx * sub_h),
		Vector2i(sub_w, sub_h)
	)

# ───────────────────────── Map helpers (read-only) ────────────────────────────
func _resolve_map() -> Node:
	if map_ref.is_empty():
		return null
	return get_node_or_null(map_ref)

func _get_map() -> Node:
	if is_instance_valid(_map_cache):
		return _map_cache
	_map_cache = _resolve_map()
	return _map_cache

func _map_surface_z(x: int, y: int) -> int:
	return MapUtilsRef.surface_z(_get_map(), x, y)

func _map_is_grassy(x: int, y: int, z: int) -> bool:
	return MapUtilsRef.is_grass_topped(_get_map(), x, y, z)

func _map_has_water(x: int, y: int) -> bool:
	return MapUtilsRef.column_has_water(_get_map(), x, y)

func _column_bottom_world(x: int, y: int, z: int) -> Vector2:
	var map := _get_map()
	var pos := MapUtilsRef.column_bottom_world(map, x, y, z)
	return pos if map != null else global_position

static func _sort_key(x: int, y: int, z: int) -> int:
	return MapUtilsRef.sort_key(x, y, z)

func _is_flat_enough(x: int, y: int) -> bool:
	return _is_flat_enough_custom(x, y, slope_max)

func _is_flat_enough_custom(x: int, y: int, slope_allow: int) -> bool:
	var xm1: int = clampi(x - 1, 0, W - 1)
	var xp1: int = clampi(x + 1, 0, W - 1)
	var ym1: int = clampi(y - 1, 0, H - 1)
	var yp1: int = clampi(y + 1, 0, H - 1)

	var z0: int = _map_surface_z(x, y); if z0 < 0: return false
	var zx1: int = _map_surface_z(xp1, y); if zx1 < 0: zx1 = z0
	var zx2: int = _map_surface_z(xm1, y); if zx2 < 0: zx2 = z0
	var zy1: int = _map_surface_z(x, yp1); if zy1 < 0: zy1 = z0
	var zy2: int = _map_surface_z(x, ym1); if zy2 < 0: zy2 = z0

	var dzx: int = abs(zx1 - zx2)
	var dzy: int = abs(zy1 - zy2)
	return max(dzx, dzy) <= slope_allow

func _find_nearby_ground(target: Vector2i, tries: int, allow_water: bool = false, require_water: bool = false, avoid_water_radius: int = 0, custom_margin: int = -1, custom_slope_allow: int = -1, require_grass_override: Variant = null, footprint_override: int = -1, shore_only: bool = false) -> GroundSpawn:
	var base_margin: int = clampi(spawn_margin_cells, 0, min(W, H) / 2)
	var margin: int = base_margin
	if custom_margin >= 0:
		margin = clampi(custom_margin, 0, min(W, H) / 2)

	var slope_allow: int = slope_max if custom_slope_allow < 0 else custom_slope_allow
	var require_grass_now: bool = require_grass_top
	if typeof(require_grass_override) == TYPE_BOOL:
		require_grass_now = bool(require_grass_override)

	for _i in range(tries):
		var rx: int = _randi_range(-2, 2)
		var ry: int = _randi_range(-2, 2)
		var cx: int = clampi(target.x + rx, margin, W - 1 - margin)
		var cy: int = clampi(target.y + ry, margin, H - 1 - margin)
		var z: int = _map_surface_z(cx, cy)
		if z < 0:
			continue
		var cell_vec := Vector2i(cx, cy)
		var water_here: bool = _map_has_water(cx, cy)
		var near_radius: int = max(1, (avoid_water_radius if avoid_water_radius > 0 else 1))
		if require_water:
			var has_near_water: bool = water_here or _has_water_within(cell_vec, near_radius)
			if not has_near_water:
				continue
		if shore_only and water_here:
			continue
		if not allow_water and water_here:
			continue
		if not allow_water and avoid_water_radius > 0 and _has_water_within(cell_vec, avoid_water_radius):
			continue
		if require_grass_now and not _map_is_grassy(cx, cy, z):
			continue
		if not _is_flat_enough_custom(cx, cy, slope_allow):
			continue
		var pos: Vector2 = _column_bottom_world(cx, cy, z)

		var halfw: int = max(0, footprint_half_width_cells)
		if footprint_override >= 0:
			halfw = max(0, footprint_override)
		if halfw > 0:
			var ys: Array[float] = []
			for dx in range(-halfw, halfw + 1):
				var nx: int = clampi(cx + dx, 0, W - 1)
				var nz: int = _map_surface_z(nx, cy)
				if nz >= 0:
					ys.append(_column_bottom_world(nx, cy, nz).y)
			if ys.size() > 0:
				ys.sort()
				pos.y = floor(ys[int(float(ys.size()) / 2.0)])

		var gs := GroundSpawn.new()
		gs.position = pos
		gs.cell = cell_vec
		gs.z = z
		return gs
	return null

func _fallback_center_spawn(allow_water: bool, require_water: bool, avoid_water_radius: int = 0) -> GroundSpawn:
	var center := Vector2i(int(float(W) / 2.0), int(float(H) / 2.0))
	var spawn := _find_nearby_ground(center, max_spawn_attempts, allow_water, require_water, avoid_water_radius)
	if spawn != null:
		return spawn
	var water_here := _map_has_water(center.x, center.y)
	if require_water and not water_here:
		return null
	if not allow_water and water_here:
		return null
	if not allow_water and avoid_water_radius > 0 and _has_water_within(center, avoid_water_radius):
		return null
	var z: int = _map_surface_z(center.x, center.y)
	if z < 0:
		return null
	var gs := GroundSpawn.new()
	gs.position = _column_bottom_world(center.x, center.y, z)
	gs.cell = center
	gs.z = z
	return gs

# ───────────────────────── Build one tree at spawn ────────────────────────────
func _build_tree_at(spawn: GroundSpawn, bark_region: Rect2i, leaf_region: Rect2i) -> void:
	# temp group: build full tree here, then bake+outline to a single sprite
	var temp: Node2D = Node2D.new()
	temp.visible = false
	add_child(temp) # short-lived; baked and freed
	_occupied_cells.append(spawn.cell)

	var bottom_world: Vector2 = spawn.position
	var tile_h_px: int = bark_region.size.y
	var usable_width: int = clampi(_trunk_width_px, 1, bark_region.size.x)
	var slice_x: int = bark_region.position.x + int((bark_region.size.x - usable_width) * 0.5)

	# Per-tree connectivity anchors (recorded rects for trunk/branches/leaves)
	var anchors: Array[Rect2] = []

	# Plan branches
	var min_px: int = int(_trunk_total_px * clamp(branch_zone_min, 0.0, 1.0))
	var max_px: int = int(_trunk_total_px * clamp(branch_zone_max, 0.0, 1.0))
	if max_px <= min_px:
		max_px = min_px + 1
	var want_count: int = clampi(_randi_range(branch_count_min, branch_count_max), 0, 64)

	var branch_targets: Array[int] = []
	var guard: int = 0
	while branch_targets.size() < want_count and guard < 200:
		guard += 1
		var y_try: int = _randi_range(min_px, max_px)
		var ok: bool = true
		for y_exist in branch_targets:
			if abs(y_exist - y_try) < branch_min_gap_px:
				ok = false
				break
		if ok:
			branch_targets.append(y_try)
	branch_targets.sort()

	var branch_lengths: Array[int] = []
	for _i in range(branch_targets.size()):
		branch_lengths.append(clampi(_randi_range(branch_length_min_px, branch_length_max_px), 3, 999))

	var next_branch_idx: int = 0
	var next_branch_px: int = (branch_targets[next_branch_idx] if branch_targets.size() > 0 else 1 << 30)
	var branch_side: int = -1

	# ── Trunk build (records anchors) ──
	var lateral: int = 0
	var current_top_y_world: float = bottom_world.y
	var built_px: int = 0

	while built_px < _trunk_total_px:
		var seg_h: int = min(_randi_range(2, 3), _trunk_total_px - built_px)

		# wobble
		if _randf() < wiggle_prob:
			var r: float = _randf() * 2.0 - 1.0
			var biased: float = r + clamp(wiggle_bias, -1.0, 1.0)
			var move: int = (1 if biased > 0.33 else (-1 if biased < -0.33 else 0))
			lateral = clampi(lateral + move, -max_lateral_px, max_lateral_px)

		# sample bark rows
		var cycle_i: int = built_px % tile_h_px
		var base_row: int = tile_h_px - 1 - cycle_i
		var rand_step: int = _randi_range(0, 2)
		var start_row: int = clampi(base_row - rand_step - (seg_h - 1), 0, tile_h_px - seg_h)
		var sample_y: int = bark_region.position.y + start_row
		var region_rect: Rect2 = Rect2(Vector2(slice_x, sample_y), Vector2(usable_width, seg_h))

		var spr: Sprite2D = Sprite2D.new()
		spr.texture = _atlas_tex
		spr.region_enabled = true
		spr.region_rect = region_rect
		spr.centered = false
		spr.texture_filter = segment_filter
		spr.z_as_relative = false
		spr.z_index = _sort_key(spawn.cell.x, spawn.cell.y, spawn.z + segments_z_offset)
		temp.add_child(spr)

		var seg_top_left_x: float = bottom_world.x + float(lateral) - float(usable_width) * 0.5
		var seg_top_left_y: float = current_top_y_world - float(seg_h)
		spr.global_position = Vector2(seg_top_left_x, seg_top_left_y)

		# record anchor rect for this trunk slice
		anchors.append(Rect2(spr.global_position, spr.region_rect.size))

		# branches that land in this band
		while built_px < next_branch_px and (built_px + seg_h) >= next_branch_px:
			var offset_in_slice: float = float(next_branch_px - built_px)
			var origin_y_world: float = current_top_y_world - offset_in_slice
			var origin_x_world: float = bottom_world.x + float(lateral)

			var side: int
			if branch_alternate_sides:
				branch_side *= -1
				side = branch_side
			else:
				var p_right: float = 0.5 + clamp(branch_side_bias, -1.0, 1.0) * 0.5
				side = (1 if _randf() < p_right else -1)

			var this_len: int = branch_lengths[next_branch_idx]
			_spawn_branch(temp, Vector2(origin_x_world, origin_y_world), spawn, side, this_len, bark_region, leaf_region, anchors)

			next_branch_idx += 1
			next_branch_px = (branch_targets[next_branch_idx] if next_branch_idx < branch_targets.size() else 1 << 30)

		current_top_y_world -= float(seg_h)
		built_px += seg_h

	# crown clump (amount & spread scale with trunk width), connected
	var crown_center: Vector2 = Vector2(
		bottom_world.x + float(lateral),
		current_top_y_world - float(leaf_crown_offset_up_px)
	)
	var crown := _scaled_crown_params()
	_spawn_leaf_clump_connected(temp, crown_center, spawn, crown.count, leaf_region, crown.radius, anchors)

	# ── Bake outlined sprite and clean up temp ────────────────────────────────
	var meta := {
		"cell": spawn.cell,
		"world": spawn.position,
		"source": TREE_SOURCE
	}
	var hover_sprite := _outline_entire_tree(temp, spawn, meta)
	if hover_sprite != null:
		var cb := Callable(self, "_on_hover_outline_clicked")
		if not hover_sprite.outline_clicked.is_connected(cb):
			hover_sprite.outline_clicked.connect(cb, CONNECT_REFERENCE_COUNTED)

# ─────────────────────────── Branch + foliage spawn ───────────────────────────
func _spawn_branch(temp: Node2D, origin_world: Vector2, spawn: GroundSpawn, dir: int, branch_len_px: int, bark_region: Rect2i, leaf_region: Rect2i, anchors: Array[Rect2]) -> void:
	var tile_h_px: int = bark_region.size.y
	var usable_w: int = clampi(branch_width_px, 1, bark_region.size.x)
	var slice_x_center: int = bark_region.position.x + int(bark_region.size.x * 0.5)

	var placed_px: int = 0
	var step_idx: int = 0

	var prev_left: float = origin_world.x - float(_trunk_width_px) * 0.5
	var prev_right: float = origin_world.x + float(_trunk_width_px) * 0.5

	var tip_cx: float = origin_world.x
	var tip_y: float = origin_world.y

	var place_single: bool = (_randf() < leaf_single_on_branch_chance)
	var single_t: float = _randf() if place_single else 0.0
	var single_done: bool = false

	while placed_px < branch_len_px:
		var seg_h_raw: int = min(_randi_range(branch_step_h_px.x, branch_step_h_px.y), branch_len_px - placed_px)
		var seg_h: int = max(2, seg_h_raw)

		var width_now: int
		if branch_thickness_taper > 0:
			var taper_div: int = max(1, branch_thickness_taper)
			var shrink: int = int(floor(float(step_idx) / float(max(1, taper_div))))
			width_now = max(branch_min_width_px, usable_w - shrink)
		else:
			width_now = max(branch_min_width_px, usable_w)

		var local_slice_x: int = slice_x_center - int(width_now * 0.5)

		var cycle_i: int = placed_px % tile_h_px
		var base_row: int = tile_h_px - 1 - cycle_i
		var rand_step: int = _randi_range(0, 2)
		var start_row: int = clampi(base_row - rand_step - (seg_h - 1), 0, tile_h_px - seg_h)
		var sample_y: int = bark_region.position.y + start_row
		var region_rect: Rect2 = Rect2(Vector2(local_slice_x, sample_y), Vector2(width_now, seg_h))

		var jitter: int = _randi_range(-branch_dev_px, branch_dev_px)
		var base_shift: int = dir * (branch_shift_px * (step_idx + 1))
		var dx: float = float(base_shift + jitter)
		if step_idx == 0:
			dx -= float(dir * branch_base_inset_px)

		var cx: float = origin_world.x + dx
		var left: float = cx - float(width_now) * 0.5
		var right: float = cx + float(width_now) * 0.5

		var overlap: float = min(right, prev_right) - max(left, prev_left)
		if overlap < float(branch_attach_min_px):
			var need: float = float(branch_attach_min_px) - overlap
			var prev_cx: float = (prev_left + prev_right) * 0.5
			if cx > prev_cx:
				cx -= need
			else:
				cx += need
			left = cx - float(width_now) * 0.5
			right = cx + float(width_now) * 0.5

		var spr: Sprite2D = Sprite2D.new()
		spr.texture = _atlas_tex
		spr.region_enabled = true
		spr.region_rect = region_rect
		spr.centered = false
		spr.texture_filter = segment_filter
		spr.z_as_relative = false
		spr.z_index = _sort_key(spawn.cell.x, spawn.cell.y, spawn.z + branch_z_offset)
		temp.add_child(spr)

		var y_advance: int = max(1, seg_h - branch_vertical_overlap_px)
		var dy: float = float(placed_px + seg_h)
		spr.global_position = Vector2(left, origin_world.y - dy)

		# record anchor rect for this branch slice
		anchors.append(Rect2(spr.global_position, spr.region_rect.size))

		tip_cx = cx
		tip_y = origin_world.y - dy

		if place_single and not single_done:
			var prog: float = float(placed_px) / float(max(1, branch_len_px))
			if prog >= single_t:
				_place_single_leaf_connected(temp, Vector2(cx, tip_y + float(seg_h) * 0.3), spawn, dir, leaf_region, anchors)
				single_done = true

		prev_left = left
		prev_right = right
		placed_px += y_advance
		step_idx += 1

	var tip_center: Vector2 = Vector2(tip_cx, tip_y - float(leaf_tip_offset_up_px))
	var tip_count: int = _randi_range(leaf_tip_count_min, leaf_tip_count_max)
	_spawn_leaf_clump_connected(temp, tip_center, spawn, tip_count, leaf_region, leaf_tip_radius_px, anchors)

# ────────────────────────────── Foliage helpers (connected) ───────────────────
func _scaled_crown_params() -> Dictionary:
	var w_min: float = float(max(1, trunk_width_px_min))
	var w_max: float = float(max(w_min + 1, trunk_width_px_max))
	var w_now: float = float(max(1, _trunk_width_px))
	var t: float = clampf((w_now - w_min) / (w_max - w_min), 0.0, 1.0)

	var count_min: int = leaf_crown_count_min
	var count_max: int = leaf_crown_count_max
	var count: int = int(round(lerpf(float(count_min), float(count_max), t)))

	var r_base: float = float(leaf_crown_radius_px)
	var r_scaled: int = int(round(lerpf(r_base * 0.6, r_base * 2.6, t)))

	return {
		"count": max(count_min, min(count, count_max)),
		"radius": max(2, r_scaled)
	}

# Axis overlap helper: returns (ox, oy) where <=0 means gap magnitude on that axis.
func _overlap_axes(a: Rect2, b: Rect2) -> Vector2:
	var ox: float = min(a.position.x + a.size.x, b.position.x + b.size.x) - max(a.position.x, b.position.x)
	var oy: float = min(a.position.y + a.size.y, b.position.y + b.size.y) - max(a.position.y, b.position.y)
	return Vector2(ox, oy)

func _rects_overlap_at_least(a: Rect2, b: Rect2, min_px: int) -> bool:
	var ov: Vector2 = _overlap_axes(a, b)
	return ov.x >= float(min_px) and ov.y >= float(min_px)

func _overlaps_any_min(r: Rect2, anchors: Array[Rect2], min_px: int) -> bool:
	for a in anchors:
		if _rects_overlap_at_least(r, a, min_px):
			return true
	return false

# Translate rect r toward anchor a by the minimal delta needed to achieve overlap >= min_px on BOTH axes.
func _snap_rect_into_contact(r: Rect2, a: Rect2, min_px: int, extra_px: int) -> Rect2:
	var result: Rect2 = r

	# Signed gaps on X (positive -> r is left of a; negative -> r is right of a)
	var dx_left_gap: float = a.position.x - (r.position.x + r.size.x)
	var dx_right_gap: float = (a.position.x + a.size.x) - r.position.x

	# Signed gaps on Y
	var dy_top_gap: float = a.position.y - (r.position.y + r.size.y)
	var dy_bottom_gap: float = (a.position.y + a.size.y) - r.position.y

	var move := Vector2.ZERO

	if dx_left_gap > 0.0:
		move.x = dx_left_gap + float(min_px + extra_px)
	elif dx_right_gap < 0.0:
		move.x = dx_right_gap - float(min_px + extra_px)

	if dy_top_gap > 0.0:
		move.y = dy_top_gap + float(min_px + extra_px)
	elif dy_bottom_gap < 0.0:
		move.y = dy_bottom_gap - float(min_px + extra_px)

	result.position += move
	return result

func _place_leaf_sprite(temp: Node2D, top_left: Vector2, spawn: GroundSpawn, leaf_region: Rect2i) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.texture = _atlas_tex
	spr.region_enabled = true
	spr.region_rect = Rect2(leaf_region.position, leaf_region.size)
	spr.centered = false
	spr.texture_filter = leaves_filter
	spr.z_as_relative = false
	spr.z_index = _sort_key(spawn.cell.x, spawn.cell.y, spawn.z + leaves_z_offset)
	spr.global_position = top_left
	if _leaf_wiggle_material != null:
		spr.material = _leaf_wiggle_material
		spr.set_instance_shader_parameter("leaf_world_pos", spr.global_position)
	temp.add_child(spr)
	return spr

func _try_connected_leaf(temp: Node2D, center_world: Vector2, spawn: GroundSpawn, leaf_region: Rect2i, radius_px: int, anchors: Array[Rect2]) -> bool:
	var sz: Vector2 = Vector2(leaf_region.size)

	# 1) Random attempts within disc, but require a minimum overlap (not just touch)
	for _i in range(max(1, leaf_connect_attempts)):
		var ox: int = _randi_range(-radius_px, radius_px)
		var max_y: int = int(sqrt(max(0.0, float(radius_px * radius_px - ox * ox))))
		var oy: int = _randi_range(-max_y, max_y)

		var top_left := Vector2(
			center_world.x + float(ox) - sz.x * 0.5,
			center_world.y + float(oy) - sz.y * 0.5
		)
		var rect := Rect2(top_left, sz)
		if _overlaps_any_min(rect, anchors, max(1, leaf_min_overlap_px)):
			var spr := _place_leaf_sprite(temp, top_left, spawn, leaf_region)
			anchors.append(Rect2(spr.global_position, spr.region_rect.size))
			return true

	# 2) Fallback: snap this rect into true overlap with the nearest anchor
	if anchors.size() > 0:
		var top_left2 := Vector2(center_world.x - sz.x * 0.5, center_world.y - sz.y * 0.5)
		var rect2 := Rect2(top_left2, sz)

		# pick nearest anchor by center distance
		var best_i: int = 0
		var best_d2: float = INF
		for i in range(anchors.size()):
			var c := anchors[i].position + anchors[i].size * 0.5
			var d2: float = (c - center_world).length_squared()
			if d2 < best_d2:
				best_d2 = d2
				best_i = i

		var snapped_rect := _snap_rect_into_contact(rect2, anchors[best_i], max(1, leaf_min_overlap_px), max(0, leaf_snap_extra_px))

		if not _overlaps_any_min(snapped_rect, anchors, max(1, leaf_min_overlap_px)):
			for a in anchors:
				var s := _snap_rect_into_contact(rect2, a, max(1, leaf_min_overlap_px), max(0, leaf_snap_extra_px))
				if _overlaps_any_min(s, anchors, max(1, leaf_min_overlap_px)):
					snapped_rect = s
					break

		var spr2 := _place_leaf_sprite(temp, snapped_rect.position, spawn, leaf_region)
		anchors.append(Rect2(spr2.global_position, spr2.region_rect.size))
		return true

	return false

func _place_single_leaf_connected(temp: Node2D, center_world: Vector2, spawn: GroundSpawn, _dir: int, leaf_region: Rect2i, anchors: Array[Rect2]) -> void:
	if leaf_region.size == Vector2i.ZERO:
		return
	_try_connected_leaf(temp, center_world, spawn, leaf_region, max(1, leaf_single_offset_radius_px), anchors)

func _spawn_leaf_clump_connected(temp: Node2D, center_world: Vector2, spawn: GroundSpawn, count: int, leaf_region: Rect2i, radius_px: int, anchors: Array[Rect2]) -> void:
	if count <= 0 or leaf_region.size == Vector2i.ZERO:
		return
	for _i in range(count):
		_try_connected_leaf(temp, center_world, spawn, leaf_region, radius_px, anchors)

# ────────────────────────────── Outline bake per tree ─────────────────────────
func _outline_entire_tree(temp: Node2D, spawn: GroundSpawn, metadata: Dictionary) -> HoverOutlineSprite:
	if temp == null:
		return null
	_configure_outline_factory()
	var z_final: int = _sort_key(spawn.cell.x, spawn.cell.y, spawn.z + leaves_z_offset + 1)
	return _outline_factory.bake_group(temp, _atlas_image, trunks_root, z_final, metadata)

func _randf() -> float:
	return _rng.randf()

func _randf_range(min_value: float, max_value: float) -> float:
	return _rng.randf_range(min_value, max_value)

func _randi_range(min_value: int, max_value: int) -> int:
	return _rng.randi_range(min_value, max_value)
