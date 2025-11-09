# map.gd — 56x56x(Z_MAX+1) cube rendered with per-tile Sprite2D (true elevation)
# Godot 4.5.1 (TileMapLayer only used as atlas/grid source; hidden)
# - FIX: Z step is now configurable; default 16 px per layer
# - Option: position in TileMap grid space (USE_TILEMAP_GRID) or pure iso math
# - Compact z_index, global Z; no YSort conflicts

class_name PlanetMap
extends Node2D

signal map_rebuild_started
signal map_rebuild_finished

const MapUtilsRef := preload("res://utils/map_utils.gd")
const RedshirtSystem := preload("res://utils/redshirt_system.gd")
const TerrainBuilder := preload("res://utils/terrain_builder.gd")

# ── Scene refs ────────────────────────────────────────────────────────────────
@onready var cam: Camera2D = $Camera2D
@onready var terrain_root: Node = $"terrain"  # only to access TileSet/atlas/grid

@export var trees_path: NodePath
@export var boulders_path: NodePath
@export var new_slice_key: Key = KEY_N

var draw_root: Node2D
var layers: Array[TileMapLayer] = []
var _redshirt_system: RedshirtSystem
var _terrain_builder: TerrainBuilder

func _suffix_int(s: String) -> int:
	var digits := ""
	for i in range(s.length() - 1, -1, -1):
		var ch := s[i]
		if ch < '0' or ch > '9': break
		digits = String(ch) + digits
	return int(digits) if digits != "" else 0

func _collect_layers() -> void:
	layers.clear()
	if terrain_root == null:
		push_warning("Map: terrain root node not found.")
		return
	for c in terrain_root.get_children():
		if c is TileMapLayer:
			layers.append(c)
	layers.sort_custom(func(a, b):
		return _suffix_int(a.name) < _suffix_int(b.name)
	)

func _get_layer(i: int) -> TileMapLayer:
	return (layers[i] if i >= 0 and i < layers.size() else null)

# ── cube size (x, y, z) ───────────────────────────────────────────────────────
const CHUNKS_X: int   = 14
const CHUNKS_Y: int   = 14
const SLICE:   int    = 4              # 14*4 = 56 cells per axis
const W: int          = CHUNKS_X * SLICE
const H: int          = CHUNKS_Y * SLICE
const Z_MAX: int      = 17             # 18 tall (0..17)
const SOURCE_ID: int  = 0

# ── placement controls ────────────────────────────────────────────────────────
const Z_STEP_PX: int = 8             # <- per-layer vertical offset in screen pixels
const USE_TILEMAP_GRID: bool = false # true: base X/Y from TileMapLayer.map_to_local

# ── earth composition controls ────────────────────────────────────────────────
const DIRT_CAP_LAYERS: int = 1
const GRADIENT_BIAS: float       = 0.0
const GRADIENT_NOISE_FREQ: float = 0.35
const GRADIENT_NOISE_AMPL: float = 0.20

# ── top face Perlin (over x,y) for grassy_dirt mask ──────────────────────────
const TOP_PERLIN_FREQ: float   = 0.10
const TOP_PERLIN_OCTAVES: int  = 3
const TOP_PERLIN_GAIN: float   = 0.55
const TOP_PERLIN_LACUN: float  = 2.0
const TOP_PERLIN_THRESH: float = 0.10

# ── grass carpet patches ──────────────────────────────────────────────────────
const CARPET_PERLIN_FREQ: float   = 0.16
const CARPET_PERLIN_OCTAVES: int  = 3
const CARPET_PERLIN_GAIN: float   = 0.55
const CARPET_PERLIN_LACUN: float  = 2.0
const CARPET_PERLIN_THRESH: float = 0.55

# ── Fractal heightmap over (x,y) → z_surf ─────────────────────────────────────
const HEIGHT_MAX_T_CAP: float = 1.5

@export_range(0.001, 0.200, 0.001, "or_greater") var height_freq: float = 0.034
@export_range(1, 12, 1, "or_greater") var height_octaves: int = 2
@export_range(0.05, 1.0, 0.01) var height_gain: float = 0.27
@export_range(1.0, 5.0, 0.05, "or_greater") var height_lacun: float = 2.9
@export_range(0.5, 8.0, 0.05, "or_greater") var height_detail_freq_mult: float = 1.85
@export_range(0.0, 1.0, 0.01) var height_detail_weight: float = 0.71
@export_range(0.0, 1.5, 0.01) var height_min_t: float = 0.0
@export_range(0.0, 1.5, 0.01) var height_max_t: float = 0.99
@export_range(0.25, 4.0, 0.05, "or_greater") var height_shape_exp: float = 1.75

# ── Water controls ─────────────────────────────────────────────────────────────
@export_range(0.0, 1.0, 0.01) var water_spawn_chance: float = 0.35
@export_range(0.0, 1.0, 0.01) var water_percent_min: float = 0.05
@export_range(0.0, 1.0, 0.01) var water_percent_max: float = 0.75

const WATER_ALPHA: float = 0.33
const REED_TILE := Vector2i(23, 17)
const REED_SPAWN_CHANCE: float = 0.4
const ENABLE_WIGGLE_SHADER: bool = false
const WiggleShader := preload("res://shaders/iso_wiggle.gdshader")
const BEAM_COLOR: Color = Color(0.75, 0.95, 1.0, 0.9)
const BEAM_DURATION: float = 2.0
const BEAM_HEIGHT_PX: float = 192.0
const BEAM_WIDTH_BASE_PX: float = 28.0
const BEAM_WIDTH_PER_AGENT_PX: float = 1.4
const BEAM_CAMERA_FOCUS_TIME: float = 0.6
const BEAM_SPAWN_DELAY: float = BEAM_CAMERA_FOCUS_TIME
const BEAM_REDSHIRT_DELAY: float = 1.0
const BEAM_LANDING_PARTICLE_AMOUNT: int = 42
const BEAM_LANDING_PARTICLE_LIFETIME: float = 2.0
const BEAM_LANDING_PARTICLE_RADIUS: float = 10.0
const BEAM_LANDING_PARTICLE_SPEED: float = 140.0
const BEAM_COLUMN_PARTICLE_AMOUNT: int = 90
const BEAM_COLUMN_PARTICLE_SPEED: float = 80.0
const BEAM_COLUMN_SEGMENTS: int = 6
const REDSHIRT_SPAWN_FADE: float = 0.35

# ── Surface detail scatter controls ───────────────────────────────────────────
const DETAIL_NOISE_FREQ: float = 0.18
const DETAIL_GRASS_THRESH: float = 0.62
const DETAIL_DENSE_THRESH: float = 0.82
const DETAIL_STONE_THRESH: float = 0.22
const DETAIL_JITTER_PX: float = 3.0

# ── atlas (families/groups) ───────────────────────────────────────────────────
const FAMILIES := {
	"red":Vector2i(1,13), "orange":Vector2i(11,13), "emerald":Vector2i(21,13),
	"teal":Vector2i(1,19), "blue":Vector2i(11,19), "violet":Vector2i(21,19),
	"brown":Vector2i(1,25), "gray-brown":Vector2i(11,25), "gray-purple":Vector2i(21,25),
	"gray-silver":Vector2i(21,30),
}
const GROUPS := {
	"dirt":        {"rel": Vector2i(2,0), "size": Vector2i(3,3)},
	"stone":       {"rel": Vector2i(7,0), "size": Vector2i(1,4)},
	"grassy_dirt": {"rel": Vector2i(9,0), "size": Vector2i(1,4)},
	"grass":       {"rel": Vector2i(0,0), "size": Vector2i(2,4)},
}
const DEFAULT_FAM_STONE := "gray-brown"
const DEFAULT_FAM_DIRT  := "brown"
const DEFAULT_FAM_GRASS := "emerald"

const STONE_FAMILY_KEYS: Array[String] = ["gray-brown", "gray-purple", "gray-silver"]
const DIRT_FAMILY_KEYS: Array[String] = ["brown", "gray-brown", "gray-purple", "gray-silver"]
const GRASS_FAMILY_KEYS: Array[String] = ["red", "orange", "emerald", "teal", "blue", "violet"]
const DEFAULT_BOULDER_TILE_MIN := Vector2i(55, 65)
const DEFAULT_BOULDER_TILE_MAX := Vector2i(57, 68)
const BOULDER_TILE_OFFSET_MIN := DEFAULT_BOULDER_TILE_MIN - FAMILIES[DEFAULT_FAM_STONE]
const BOULDER_TILE_OFFSET_MAX := DEFAULT_BOULDER_TILE_MAX - FAMILIES[DEFAULT_FAM_STONE]
const REDSHIRT_SORT_BIAS: int = 64
const REDSHIRT_WANDER_RADIUS: int = 6
const REDSHIRT_WANDER_RADIUS_CLICK: int = 4
const REDSHIRT_WANDER_RADIUS_JITTER: int = 3
const REDSHIRT_MOVE_INTERVAL: Vector2 = Vector2(1.0, 3.2)
const REDSHIRT_SECONDS_PER_TILE: float = 0.38
const REDSHIRT_FOCUS_LERP_TIME: float = 0.65
const FOCUS_CIRCLE_SEGMENTS: int = 48
const FOCUS_CIRCLE_COLOR := Color(1.0, 0.95, 0.25, 0.7)
const FOCUS_CIRCLE_WIDTH: float = 2.0

# ── noise fields ──────────────────────────────────────────────────────────────
var rng_seed: int = 0
var _stone_family_key: String = DEFAULT_FAM_STONE
var _dirt_family_key: String = DEFAULT_FAM_DIRT
var _grass_family_key: String = DEFAULT_FAM_GRASS
var _trees_cache: TreeGen
var _boulders_cache: BoulderGen
var _obstacle_sources: Dictionary = {}
var _obstacle_lookup: Dictionary = {}

# ── cached atlas source / metrics ─────────────────────────────────────────────
var _atlas_src: TileSetAtlasSource
var _atlas_tex: Texture2D
var _tile_w := 16.0
var _tile_h := 8.0
var _base_tm: TileMapLayer
var _water_surface_material: ShaderMaterial
var _water_depth_material: ShaderMaterial
var _grass_blade_material: ShaderMaterial
var _reed_material: ShaderMaterial
var _slice_rng := RandomNumberGenerator.new()

# ── lifecycle ─────────────────────────────────────────────────────────────────
func _ready() -> void:
	_collect_layers()
	_setup_draw_root()
	_ensure_redshirt_system()
	_ensure_terrain_builder()
	_bind_atlas_source()
	_ensure_redshirt_system()
	_setup_wiggle_materials()
	_hide_tilemap_layers()
	_bind_dressing_signals()
	new_slice()

func _setup_draw_root() -> void:
	var existing := get_node_or_null("DrawRoot")
	if existing and existing is Node2D:
		draw_root = existing
		for c in draw_root.get_children():
			c.queue_free()
	else:
		draw_root = Node2D.new()
		draw_root.name = "DrawRoot"
	add_child(draw_root)
	draw_root.y_sort_enabled = false
	_ensure_redshirt_system()

func _ensure_redshirt_system() -> void:
	if _redshirt_system == null:
		_redshirt_system = RedshirtSystem.new()
		_redshirt_system.setup(self)
	if draw_root != null:
		_redshirt_system.set_draw_root(draw_root)
	if _atlas_src != null and _atlas_tex != null:
		_redshirt_system.set_atlas(_atlas_src, _atlas_tex)

func _ensure_terrain_builder() -> void:
	if _terrain_builder == null:
		_terrain_builder = TerrainBuilder.new()
		_terrain_builder.setup(self)

func _apply_slice_seed() -> void:
	if _terrain_builder != null:
		_terrain_builder.apply_seed(rng_seed)
	_slice_rng.seed = rng_seed ^ 0xDEADBEEF
	var trees := _get_tree_gen()
	if trees != null and trees.has_method("set_seed"):
		trees.set_seed(rng_seed ^ 0x13572468)
	var boulders := _get_boulder_gen()
	if boulders != null and boulders.has_method("set_seed"):
		boulders.set_seed(rng_seed ^ 0x2468ACE1)
	if _redshirt_system != null:
		_redshirt_system.set_seed(rng_seed ^ 0x77F00F77)

func _bind_atlas_source() -> void:
	_base_tm = _get_layer(0)
	if _base_tm == null or _base_tm.tile_set == null:
		push_warning("Map: No TileSet found on Terrain0 (using defaults).")
		return
	var src := _base_tm.tile_set.get_source(SOURCE_ID)
	if src is TileSetAtlasSource:
		_atlas_src = src
		_atlas_tex = _atlas_src.texture
		var tsz: Vector2i = _base_tm.tile_set.tile_size
		_tile_w = float(tsz.x)
		_tile_h = float(tsz.y)
	else:
		push_warning("Map: TileSet source %d is not a TileSetAtlasSource." % SOURCE_ID)

func _hide_tilemap_layers() -> void:
	for tm in layers:
		if tm:
			tm.visible = false
			tm.clear()

# ── projection & sort helpers ─────────────────────────────────────────────────
static func sort_key(x: int, y: int, z: int) -> int:
	return MapUtilsRef.sort_key(x, y, z)

func project_iso3d(x: float, y: float, z: float) -> Vector2:
	if USE_TILEMAP_GRID and _base_tm != null:
		# Use TileMap grid; map_to_local returns the cell's draw origin.
		var cell_pos: Vector2 = _base_tm.map_to_local(Vector2i(int(x), int(y)))
		return cell_pos - Vector2(0, float(Z_STEP_PX) * z)
	else:
		# Pure diamond iso math based on tile size
		var sx := (x - y) * (_tile_w * 0.5)
		var sy := (x + y) * (_tile_h * 0.5) - z * float(Z_STEP_PX)
		return Vector2(sx, sy)

func _project_iso3d(x: float, y: float, z: float) -> Vector2:
	return project_iso3d(x, y, z)

func cell_to_world(cell: Vector2i, z_override: Variant = null) -> Vector2:
	var z_value: int = 0
	if z_override != null:
		z_value = int(z_override)
	else:
		z_value = surface_z_at(cell.x, cell.y)
	return project_iso3d(float(cell.x), float(cell.y), float(z_value))

func world_to_cell(world: Vector2, search_radius: int = 2) -> Vector2i:
	if USE_TILEMAP_GRID and _base_tm != null:
		var mapped: Vector2i = _base_tm.local_to_map(world)
		return _clamp_cell(mapped)
	var approx: Vector2 = _approximate_cell_from_world(world)
	var estimated: Vector2i = _clamp_cell(Vector2i(roundi(approx.x), roundi(approx.y)))
	var best_cell: Vector2i = estimated
	var best_dist: float = INF
	var radius: int = max(0, search_radius)
	var min_x: int = max(0, estimated.x - radius)
	var max_x: int = min(W - 1, estimated.x + radius)
	var min_y: int = max(0, estimated.y - radius)
	var max_y: int = min(H - 1, estimated.y + radius)
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var cell: Vector2i = Vector2i(x, y)
			var projected: Vector2 = cell_to_world(cell)
			var dist: float = projected.distance_squared_to(world)
			if dist < best_dist:
				best_dist = dist
				best_cell = cell
	return best_cell

func _approximate_cell_from_world(world: Vector2) -> Vector2:
	var half_w: float = max(0.0001, _tile_w * 0.5)
	var half_h: float = max(0.0001, _tile_h * 0.5)
	var nx: float = world.x / half_w
	var ny: float = world.y / half_h
	var est_x: float = 0.5 * (ny + nx)
	var est_y: float = 0.5 * (ny - nx)
	return Vector2(est_x, est_y)

func _clamp_cell(cell: Vector2i) -> Vector2i:
	return Vector2i(clampi(cell.x, 0, W - 1), clampi(cell.y, 0, H - 1))

func _place_sprite(
	atlas_xy: Vector2i,
	x: int,
	y: int,
	z: int,
	tint: Color = Color(1,1,1,1),
	sprite_material: Material = null
) -> void:
	if _atlas_src == null or _atlas_tex == null:
		return
	var region: Rect2i = _atlas_src.get_tile_texture_region(atlas_xy)
	if region.size == Vector2i.ZERO:
		return
	var sp := Sprite2D.new()
	sp.texture = _atlas_tex
	sp.region_enabled = true
	sp.region_rect = Rect2(region.position, region.size)

	var p := project_iso3d(float(x), float(y), float(z))

	# Anchor so the diamond sits correctly; TileMap grid origin matches this offset.
	# (If your atlas differs, tweak these two numbers.)
	var anchor := Vector2(_tile_w * 0.5, _tile_h)
	sp.position = p - anchor
	sp.centered = false
	if sprite_material != null:
		sp.material = sprite_material
	sp.z_as_relative = false
	sp.z_index = sort_key(x, y, z)
	sp.modulate = tint
	draw_root.add_child(sp)

func _place_detail_sprite(
	atlas_xy: Vector2i,
	x: int,
	y: int,
	z: int,
	offset: Vector2 = Vector2.ZERO,
	scale_vec: Vector2 = Vector2.ONE,
	rotation_radians: float = 0.0,
	tint: Color = Color(1,1,1,1)
  ) -> void:
	if _atlas_src == null or _atlas_tex == null:
		return
	var region: Rect2i = _atlas_src.get_tile_texture_region(atlas_xy)
	if region.size == Vector2i.ZERO:
		return
	var sp := Sprite2D.new()
	sp.texture = _atlas_tex
	sp.region_enabled = true
	sp.region_rect = Rect2(region.position, region.size)
	var p := project_iso3d(float(x), float(y), float(z))
	var anchor := Vector2(_tile_w * 0.5, _tile_h)
	sp.position = p - anchor + offset
	sp.centered = false
	sp.z_as_relative = false
	sp.z_index = sort_key(x, y, z)
	sp.modulate = tint
	sp.scale = scale_vec
	sp.rotation = rotation_radians
	draw_root.add_child(sp)

func _make_wiggle_material(params: Dictionary) -> ShaderMaterial:
	if WiggleShader == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = WiggleShader
	for key in params.keys():
		mat.set_shader_parameter(StringName(key), params[key])
	return mat

func _setup_wiggle_materials() -> void:
	_water_surface_material = null
	_water_depth_material = null
	_grass_blade_material = null
	_reed_material = null
	if not ENABLE_WIGGLE_SHADER or WiggleShader == null:
		return
	_water_surface_material = _make_wiggle_material({
		"axis": Vector2(0.35, -0.2),
		"amplitude_px": 1.6,
		"frequency": 5.4,
		"speed": 0.65,
		"noise_mix": 0.45,
		"alpha_soften": 0.1,
		"world_phase_scale": Vector2(0.009, 0.009),
		"base_phase": 0.0
	})
	_water_depth_material = _make_wiggle_material({
		"axis": Vector2(0.25, -0.15),
		"amplitude_px": 0.6,
		"frequency": 4.5,
		"speed": 0.5,
		"noise_mix": 0.4,
		"alpha_soften": 0.05,
		"world_phase_scale": Vector2(0.008, 0.008),
		"base_phase": 0.4
	})
	_grass_blade_material = _make_wiggle_material({
		"axis": Vector2(0.65, -0.3),
		"amplitude_px": 0.85,
		"frequency": 3.5,
		"speed": 1.35,
		"noise_mix": 0.3,
		"world_phase_scale": Vector2(0.02, 0.02),
		"base_phase": 1.1
	})
	_reed_material = _make_wiggle_material({
		"axis": Vector2(0.55, -0.35),
		"amplitude_px": 1.1,
		"frequency": 2.6,
		"speed": 1.0,
		"noise_mix": 0.4,
		"world_phase_scale": Vector2(0.012, 0.012),
		"base_phase": 2.2
	})

# ── atlas helpers → atlas coords ──────────────────────────────────────────────
func _family_base(fam: String) -> Vector2i:
	return (FAMILIES.get(fam, FAMILIES["teal"]) as Vector2i)

func _pick_family(options: Array[String], current: String, ensure_new: bool) -> String:
	if options.is_empty():
		return current
	if options.size() == 1:
		return options[0]
	var max_attempts: int = max(1, options.size() * 3)
	for _i in range(max_attempts):
		var candidate: String = options[randi_range(0, options.size() - 1)]
		if not ensure_new or candidate != current:
			return candidate
	return options[randi_range(0, options.size() - 1)]

func _randomize_palette(ensure_new: bool = true) -> bool:
	var new_stone: String = _pick_family(STONE_FAMILY_KEYS, _stone_family_key, ensure_new)
	var new_dirt: String = _pick_family(DIRT_FAMILY_KEYS, _dirt_family_key, ensure_new)
	var new_grass: String = _pick_family(GRASS_FAMILY_KEYS, _grass_family_key, ensure_new)

	var changed := (new_stone != _stone_family_key) or (new_dirt != _dirt_family_key) or (new_grass != _grass_family_key)

	_stone_family_key = new_stone
	_dirt_family_key = new_dirt
	_grass_family_key = new_grass
	return changed

func _apply_palette_to_boulders() -> void:
	var b := _get_boulder_gen()
	if b == null:
		return
	var base: Vector2i = _family_base(_stone_family_key)
	var min_corner: Vector2i = base + BOULDER_TILE_OFFSET_MIN
	var max_corner: Vector2i = base + BOULDER_TILE_OFFSET_MAX
	b.set_tile_region(min_corner, max_corner)

func _bind_dressing_signals() -> void:
	var cb := Callable(self, "_on_dressing_highlight_clicked")
	var trees := _get_tree_gen()
	if trees != null and trees.has_signal("highlight_clicked") and not trees.highlight_clicked.is_connected(cb):
		trees.highlight_clicked.connect(cb, CONNECT_REFERENCE_COUNTED)
	var boulders := _get_boulder_gen()
	if boulders != null and boulders.has_signal("highlight_clicked") and not boulders.highlight_clicked.is_connected(cb):
		boulders.highlight_clicked.connect(cb, CONNECT_REFERENCE_COUNTED)

func _get_tree_gen() -> TreeGen:
	if _trees_cache != null and is_instance_valid(_trees_cache):
		return _trees_cache
	if trees_path.is_empty():
		return null
	_trees_cache = get_node_or_null(trees_path) as TreeGen
	return _trees_cache

func _get_boulder_gen() -> BoulderGen:
	if _boulders_cache != null and is_instance_valid(_boulders_cache):
		return _boulders_cache
	if boulders_path.is_empty():
		return null
	_boulders_cache = get_node_or_null(boulders_path) as BoulderGen
	return _boulders_cache

func _stone_atlas() -> Vector2i:
	var rel: Vector2i = GROUPS["stone"]["rel"]
	return _family_base(_stone_family_key) + rel + Vector2i(0, 1)

func _dirt_atlas() -> Vector2i:
	var rel: Vector2i = GROUPS["dirt"]["rel"]
	var size: Vector2i = GROUPS["dirt"]["size"]
	return _family_base(_dirt_family_key) + Vector2i(rel.x + size.x - 1, rel.y + 1)

func register_obstacle_cells(source: StringName, cells: Array[Vector2i]) -> void:
	var key: StringName = (source if source is StringName else StringName(str(source)))
	var copy: Array[Vector2i] = []
	if cells != null:
		for cell_variant in cells:
			if cell_variant is Vector2i:
				copy.append(cell_variant)
	_obstacle_sources[key] = copy
	_rebuild_obstacle_lookup()

func _rebuild_obstacle_lookup() -> void:
	_obstacle_lookup.clear()
	for entry in _obstacle_sources.values():
		if entry is Array:
			for cell_variant in entry:
				if cell_variant is Vector2i:
					var cell: Vector2i = cell_variant
					_obstacle_lookup[_obstacle_key(cell)] = true

func is_obstacle_cell(x: int, y: int) -> bool:
	return _obstacle_lookup.has(_obstacle_key(Vector2i(x, y)))

func _obstacle_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]

func _grassy_dirt_atlas() -> Vector2i:
	var rel: Vector2i = GROUPS["grassy_dirt"]["rel"]
	return _family_base(_grass_family_key) + rel + Vector2i(0, 1)

func _grass_blade_atlas() -> Vector2i:
	var rel: Vector2i = GROUPS["grass"]["rel"]
	var size: Vector2i = GROUPS["grass"]["size"]
	return _family_base(_grass_family_key) + rel + Vector2i(randi_range(0, size.x - 1), 3)

func _stone_pebble_atlas() -> Vector2i:
	var rel: Vector2i = GROUPS["stone"]["rel"]
	var size: Vector2i = GROUPS["stone"]["size"]
	return _family_base(_stone_family_key) + rel + Vector2i(randi_range(0, size.x - 1), 0)

func _water_surface_atlas() -> Vector2i:
	return Vector2i(54, 34)

func _water_depth_atlas() -> Vector2i:
	return Vector2i(72, 35)

func surface_z_at(x: int, y: int) -> int:
	if _terrain_builder == null:
		return 0
	return _terrain_builder.surface_z_at(x, y)

func is_water_column(x: int, y: int) -> bool:
	if _terrain_builder == null:
		return false
	return _terrain_builder.is_water_column(x, y)

func is_grass_topped(x: int, y: int, z: int) -> bool:
	if _terrain_builder == null:
		return false
	return _terrain_builder.is_grass_topped(x, y, z)

func get_height_settings() -> Dictionary:
	return {
		"height_freq": height_freq,
		"height_octaves": height_octaves,
		"height_gain": height_gain,
		"height_lacun": height_lacun,
		"height_detail_freq_mult": height_detail_freq_mult,
		"height_detail_weight": height_detail_weight,
		"height_min_t": height_min_t,
		"height_max_t": height_max_t,
		"height_shape_exp": height_shape_exp,
	}

func apply_height_settings(settings: Dictionary, reseed: bool = false) -> void:
	if settings.has("height_freq"):
		height_freq = max(0.001, float(settings["height_freq"]))
	if settings.has("height_octaves"):
		height_octaves = max(1, int(settings["height_octaves"]))
	if settings.has("height_gain"):
		height_gain = clampf(float(settings["height_gain"]), 0.01, 1.0)
	if settings.has("height_lacun"):
		height_lacun = max(0.5, float(settings["height_lacun"]))
	if settings.has("height_detail_freq_mult"):
		height_detail_freq_mult = max(0.1, float(settings["height_detail_freq_mult"]))
	if settings.has("height_detail_weight"):
		height_detail_weight = clampf(float(settings["height_detail_weight"]), 0.0, 1.0)
	if settings.has("height_min_t"):
		height_min_t = clampf(float(settings["height_min_t"]), 0.0, HEIGHT_MAX_T_CAP - 0.01)
	if settings.has("height_max_t"):
		height_max_t = clampf(float(settings["height_max_t"]), 0.01, HEIGHT_MAX_T_CAP)
	if settings.has("height_shape_exp"):
		height_shape_exp = max(0.01, float(settings["height_shape_exp"]))
	_normalize_height_bounds()
	rebuild_world(reseed)

func rebuild_world(reseed: bool = false) -> void:
	var chosen_seed: int = (-1 if reseed else rng_seed)
	_rebuild(chosen_seed)

func _normalize_height_bounds() -> void:
	height_min_t = clampf(height_min_t, 0.0, HEIGHT_MAX_T_CAP - 0.01)
	height_max_t = clampf(height_max_t, height_min_t + 0.01, HEIGHT_MAX_T_CAP)

func get_dimensions() -> Vector2i:
	return Vector2i(W, H)

func get_max_elevation() -> int:
	return Z_MAX

# ── rebuild ───────────────────────────────────────────────────────────────────
func _clear_drawables() -> void:
	if not draw_root:
		return
	if _redshirt_system != null:
		_redshirt_system.clear_for_rebuild()
	for c in draw_root.get_children():
		c.queue_free()

func _center_camera_on_middle() -> void:
	var cx := W >> 1
	var cy := H >> 1
	var cz := surface_z_at(cx, cy)
	var p := project_iso3d(cx, cy, cz)
	cam.global_position = p

func _rebuild(new_seed: int = -1) -> void:
	map_rebuild_started.emit()
	_clear_drawables()
	rng_seed = (new_seed if new_seed != -1 else randi())
	_apply_slice_seed()
	var surfaces: Array = []
	if _terrain_builder != null:
		surfaces = _terrain_builder.build_terrain()
	_spawn_shore_reeds(surfaces)
	if _redshirt_system != null:
		_redshirt_system.spawn_redshirts(surfaces)
	var camera_centered := (_redshirt_system != null and _redshirt_system.camera_centered_by_spawn())
	if not camera_centered:
		_center_camera_on_middle()
	if _redshirt_system != null:
		_redshirt_system.refresh_focus_indicator()
	_bind_dressing_signals()
	map_rebuild_finished.emit()

# ── main build (per-column surface, fill below, water where air≤sea) ──────────
const SEA_Z := 0

func _spawn_shore_reeds(surfaces: Array) -> void:
	if _terrain_builder == null or not _terrain_builder.has_active_water():
		return
	var atlas_reed := REED_TILE
	for y in range(H):
		for x in range(W):
			if is_water_column(x, y):
				continue
			if not _adjacent_to_water(x, y):
				continue
			if _slice_rng.randf() > REED_SPAWN_CHANCE:
				continue
			var z_surf: int = (surfaces[y][x] as int)
			if z_surf + 1 <= Z_MAX:
				_place_sprite(atlas_reed, x, y, z_surf + 1, Color(1, 1, 1, 1), _reed_material)

func _adjacent_to_water(x: int, y: int) -> bool:
	var offsets := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for off in offsets:
		var nx: int = x + off.x
		var ny: int = y + off.y
		if nx < 0 or nx >= W or ny < 0 or ny >= H:
			continue
		if is_water_column(nx, ny):
			return true
	return false

func _on_dressing_highlight_clicked(cell: Vector2i, _world_position: Vector2, _source: StringName) -> void:
	if _redshirt_system != null:
		_redshirt_system.handle_dressing_highlight(cell)


func _regenerate_object_layers(reseed_boulders: bool) -> void:
	var trees: TreeGen = _get_tree_gen()
	if trees != null:
		trees.regenerate_for_new_slice()
	var boulders: BoulderGen = _get_boulder_gen()
	if boulders != null:
		boulders.regenerate_boulders(reseed_boulders)

func new_slice() -> void:
	randomize()
	_randomize_palette(true)
	_apply_palette_to_boulders()
	_rebuild(randi())
	_regenerate_object_layers(false)

# ── Input (R = rebuild) ───────────────────────────────────────────────────────
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		var has_modifier: bool = e.shift_pressed or e.alt_pressed or e.ctrl_pressed or e.meta_pressed
		if new_slice_key != KEY_NONE and e.keycode == new_slice_key and not has_modifier:
			new_slice()
			return
		if e.keycode == KEY_R and not has_modifier:
			_rebuild()
