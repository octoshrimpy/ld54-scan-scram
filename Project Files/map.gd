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
const RedshirtSpawnerScript := preload("res://utils/redshirt_spawner.gd")
const RedshirtAgentScript := preload("res://utils/redshirt_agent.gd")

# ── Scene refs ────────────────────────────────────────────────────────────────
@onready var cam: Camera2D = $Camera2D
@onready var terrain_root: Node = $"terrain"  # only to access TileSet/atlas/grid

@export var trees_path: NodePath
@export var boulders_path: NodePath
@export var new_slice_key: Key = KEY_N

var draw_root: Node2D
var layers: Array[TileMapLayer] = []

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
const REDSHIRT_WANDER_RADIUS_JITTER: int = 3
const REDSHIRT_MOVE_INTERVAL: Vector2 = Vector2(1.0, 3.2)
const REDSHIRT_SECONDS_PER_TILE: float = 0.38

# ── noise fields ──────────────────────────────────────────────────────────────
var top_noise: FastNoiseLite     = FastNoiseLite.new()
var carpet_noise: FastNoiseLite  = FastNoiseLite.new()
var grad_noise: FastNoiseLite    = FastNoiseLite.new()
var height_u1: FastNoiseLite     = FastNoiseLite.new()
var height_u2: FastNoiseLite     = FastNoiseLite.new()
var detail_noise: FastNoiseLite  = FastNoiseLite.new()
var rng_seed: int = 0
var _water_active: bool = false
var _water_level: int = -1
var _water_columns: Array = []
var _stone_family_key: String = DEFAULT_FAM_STONE
var _dirt_family_key: String = DEFAULT_FAM_DIRT
var _grass_family_key: String = DEFAULT_FAM_GRASS
var _trees_cache: TreeGen
var _boulders_cache: BoulderGen
var _redshirt_spawner = RedshirtSpawnerScript.new()
var _camera_centered_by_spawn: bool = false
var _camera_focus_tween: Tween
var _active_redshirts: Array = []

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

# ── lifecycle ─────────────────────────────────────────────────────────────────
func _ready() -> void:
	randomize()
	_collect_layers()
	_setup_draw_root()
	_setup_noises()
	_bind_atlas_source()
	_setup_wiggle_materials()
	_hide_tilemap_layers()
	_rebuild()

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

# ── noises setup ──────────────────────────────────────────────────────────────
func _setup_noises() -> void:
	top_noise.noise_type         = FastNoiseLite.TYPE_PERLIN
	top_noise.frequency          = TOP_PERLIN_FREQ
	top_noise.fractal_octaves    = TOP_PERLIN_OCTAVES
	top_noise.fractal_gain       = TOP_PERLIN_GAIN
	top_noise.fractal_lacunarity = TOP_PERLIN_LACUN

	carpet_noise.noise_type         = FastNoiseLite.TYPE_PERLIN
	carpet_noise.frequency          = CARPET_PERLIN_FREQ
	carpet_noise.fractal_octaves    = CARPET_PERLIN_OCTAVES
	carpet_noise.fractal_gain       = CARPET_PERLIN_GAIN
	carpet_noise.fractal_lacunarity = CARPET_PERLIN_LACUN

	grad_noise.noise_type         = FastNoiseLite.TYPE_PERLIN
	grad_noise.frequency          = GRADIENT_NOISE_FREQ
	grad_noise.fractal_octaves    = 2
	grad_noise.fractal_gain       = 0.5
	grad_noise.fractal_lacunarity = 2.0

	detail_noise.noise_type         = FastNoiseLite.TYPE_PERLIN
	detail_noise.frequency          = DETAIL_NOISE_FREQ
	detail_noise.fractal_octaves    = 2
	detail_noise.fractal_gain       = 0.5
	detail_noise.fractal_lacunarity = 2.0

	for n in [height_u1, height_u2]:
		n.noise_type         = FastNoiseLite.TYPE_PERLIN
		n.frequency          = 1.0
		n.fractal_type       = FastNoiseLite.FRACTAL_NONE
		n.fractal_octaves    = 1
		n.fractal_gain       = 1.0
		n.fractal_lacunarity = 2.0

# ── height helpers ────────────────────────────────────────────────────────────
func surface_z_at(x: int, y: int) -> int:
	return _surface_z_at(x, y)

func _fbm_height(noise: FastNoiseLite, x: float, y: float, base_freq: float) -> float:
	var freq := base_freq
	var amplitude := 1.0
	var total := 0.0
	var norm := 0.0
	var octave_count: int = max(1, height_octaves)
	for _i in range(octave_count):
		total += noise.get_noise_2d(x * freq, y * freq) * amplitude
		norm += amplitude
		freq *= height_lacun
		amplitude *= height_gain
	return (total / norm) if norm > 0.0 else 0.0

func _surface_z_at(x: int, y: int) -> int:
	var xf := float(x)
	var yf := float(y)
	var base := _fbm_height(height_u1, xf, yf, height_freq)
	var detail := _fbm_height(height_u2, xf, yf, height_freq * height_detail_freq_mult)
	var combined := lerpf(base, detail, clampf(height_detail_weight, 0.0, 1.0))
	var normalized := clampf(0.5 + 0.5 * combined, 0.0, 1.0)
	normalized = pow(normalized, height_shape_exp)
	var min_t := clampf(height_min_t, 0.0, HEIGHT_MAX_T_CAP)
	var max_t := clampf(height_max_t, min_t + 1e-5, HEIGHT_MAX_T_CAP)
	var zf: float = lerpf(min_t * float(Z_MAX), max_t * float(Z_MAX), normalized)
	return clampi(int(round(zf)), 0, Z_MAX)

func is_water_column(x: int, y: int) -> bool:
	if not _water_active:
		return false
	if y < 0 or y >= _water_columns.size():
		return false
	var row: Array = _water_columns[y]
	if x < 0 or x >= row.size():
		return false
	return bool(row[x])

func is_grass_topped(x: int, y: int, z: int) -> bool:
	if z != _surface_z_at(x, y):
		return false
	if is_water_column(x, y):
		return false
	var n_grass: float = 0.5 + 0.5 * top_noise.get_noise_2d(float(x), float(y))
	return n_grass > TOP_PERLIN_THRESH

func _detail_offset(x: int, y: int, weight: float) -> Vector2:
	var jitter_u := detail_noise.get_noise_3d(float(x), float(y), 17.0)
	var jitter_v := detail_noise.get_noise_3d(float(x), float(y), -41.0)
	var scale_factor: float = DETAIL_JITTER_PX * clampf(0.25 + weight * 0.75, 0.0, 1.0)
	return Vector2(jitter_u, jitter_v) * scale_factor

func _spawn_surface_detail(x: int, y: int, z_surf: int) -> void:
	if is_water_column(x, y) or z_surf < SEA_Z:
		return
	var n := 0.5 + 0.5 * detail_noise.get_noise_2d(float(x), float(y))
	if n > DETAIL_GRASS_THRESH and z_surf + 1 <= Z_MAX:
		var weight := clampf((n - DETAIL_GRASS_THRESH) / max(0.001, 1.0 - DETAIL_GRASS_THRESH), 0.0, 1.0)
		var offset := _detail_offset(x, y, weight)
		var scale_f := lerpf(0.85, 1.2, weight)
		var tint := Color(1.0, lerpf(0.9, 1.0, weight), 1.0, 0.9 + 0.1 * weight)
		var z_top: int = min(z_surf + 1, Z_MAX)
		_place_detail_sprite(_grass_blade_atlas(), x, y, z_top, offset, Vector2(scale_f, scale_f), 0.05 * (weight - 0.5), tint)
		if n > DETAIL_DENSE_THRESH:
			var weight2 := clampf((n - DETAIL_DENSE_THRESH) / max(0.001, 1.0 - DETAIL_DENSE_THRESH), 0.0, 1.0)
			var offset2 := _detail_offset(x + 37, y + 19, weight2) * 0.5
			var scale_f2 := lerpf(0.7, 1.0, weight2)
			_place_detail_sprite(_grass_blade_atlas(), x, y, z_top, offset2, Vector2(scale_f2, scale_f2), -0.05 * (weight2 - 0.5), tint)
	elif n < DETAIL_STONE_THRESH:
		var weight_stone := clampf((DETAIL_STONE_THRESH - n) / max(0.001, DETAIL_STONE_THRESH), 0.0, 1.0)
		var offset_stone := _detail_offset(x + 11, y + 53, weight_stone) * 0.6
		var scale_s := lerpf(0.6, 0.95, weight_stone)
		var tint_s := Color(lerpf(0.8, 1.0, weight_stone), lerpf(0.8, 0.95, weight_stone), lerpf(0.8, 0.9, weight_stone), 0.85 + 0.15 * weight_stone)
		_place_detail_sprite(_stone_pebble_atlas(), x, y, z_surf, offset_stone, Vector2(scale_s, scale_s), 0.0, tint_s)

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
	_despawn_redshirts()
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
	_camera_centered_by_spawn = false
	rng_seed = (new_seed if new_seed != -1 else randi())
	top_noise.seed     = rng_seed ^ 0xABCDEF01
	carpet_noise.seed  = rng_seed ^ 0xBADC0DED
	grad_noise.seed    = rng_seed ^ 0x13579BDF
	height_u1.seed     = rng_seed ^ 0x0F0F0F0F
	height_u2.seed     = rng_seed ^ 0xF00DFACE
	detail_noise.seed  = rng_seed ^ 0x2468ACE1
	_spawn_cube_terrain()
	if not _camera_centered_by_spawn:
		_center_camera_on_middle()
	map_rebuild_finished.emit()

# ── main build (per-column surface, fill below, water where air≤sea) ──────────
const SEA_Z := 0

func _spawn_cube_terrain() -> void:
	var atlas_stone := _stone_atlas()
	var atlas_dirt  := _dirt_atlas()
	var atlas_grass := _grassy_dirt_atlas()
	var atlas_water_surface := _water_surface_atlas()
	var atlas_water_depth := _water_depth_atlas()
	var water_tint := Color(1.0, 1.0, 1.0, WATER_ALPHA)

	_water_columns.clear()
	for _y in range(H):
		var row: Array = []
		row.resize(W)
		for i in range(W):
			row[i] = false
		_water_columns.append(row)

	var surfaces: Array = []
	var grass_mask: Array = []
	var min_grass: int = Z_MAX
	var max_grass: int = 0
	var grass_found := false
	for y in range(H):
		var row_surf: Array = []
		var row_grass: Array = []
		for x in range(W):
			var z_surf: int = _surface_z_at(x, y)
			row_surf.append(z_surf)
			var n_grass: float = 0.5 + 0.5 * top_noise.get_noise_2d(float(x), float(y))
			var is_grass := n_grass > TOP_PERLIN_THRESH
			row_grass.append(is_grass)
			if is_grass:
				grass_found = true
				min_grass = min(min_grass, z_surf)
				max_grass = max(max_grass, z_surf)
		surfaces.append(row_surf)
		grass_mask.append(row_grass)

	var min_percent: float = min(water_percent_min, water_percent_max)
	var max_percent: float = max(water_percent_min, water_percent_max)
	min_percent = clampf(min_percent, 0.0, 1.0)
	max_percent = clampf(max_percent, 0.0, 1.0)

	_water_active = false
	_water_level = -1
	if grass_found and max_percent > 0.0 and randf() < clampf(water_spawn_chance, 0.0, 1.0):
		var span: int = max_grass - min_grass
		var percent: float = (max_percent if is_equal_approx(min_percent, max_percent) else randf_range(min_percent, max_percent))
		var level_f := float(min_grass) + float(span) * percent
		_water_level = clampi(int(round(level_f)), 0, Z_MAX)
		_water_active = _water_level >= 0

	for y in range(H):
		var row_surf: Array = surfaces[y]
		var row_grass: Array = grass_mask[y]
		var water_row: Array = _water_columns[y]
		for x in range(W):
			var z_surf: int = row_surf[x]
			var column_has_water := false
			if _water_active:
				var water_cap: int = min(_water_level, Z_MAX)
				for z in range(0, water_cap + 1):
					if z > z_surf:
						var atlas_xy := (atlas_water_surface if z == water_cap else atlas_water_depth)
						var mat := (_water_surface_material if z == water_cap else _water_depth_material)
						_place_sprite(atlas_xy, x, y, z, water_tint, mat)
						column_has_water = true
			water_row[x] = column_has_water
			var has_grass_top := bool(row_grass[x]) and not column_has_water
			if has_grass_top:
				_place_sprite(atlas_grass, x, y, z_surf)
				var n_carpet: float = 0.5 + 0.5 * carpet_noise.get_noise_2d(float(x), float(y))
				if n_carpet > CARPET_PERLIN_THRESH and z_surf + 1 <= Z_MAX:
					_place_sprite(_grass_blade_atlas(), x, y, z_surf + 1, Color(1, 1, 1, 1), _grass_blade_material)
			else:
				_place_sprite(atlas_dirt, x, y, z_surf)

			for z in range(max(0, z_surf - DIRT_CAP_LAYERS), z_surf):
				_place_sprite(atlas_dirt, x, y, z)

			var grad_top: int = max(0, z_surf - DIRT_CAP_LAYERS - 1)
			for z in range(0, grad_top + 1):
				var base_p: float = float(z) / float(max(1, grad_top)) + GRADIENT_BIAS
				var jitter: float = GRADIENT_NOISE_AMPL * (0.5 + 0.5 * grad_noise.get_noise_2d(float(x), float(y)))
				var p_dirt: float = clampf(base_p + (jitter - GRADIENT_NOISE_AMPL * 0.5), 0.0, 1.0)
				var atlas := (atlas_dirt if randf() < p_dirt else atlas_stone)
				_place_sprite(atlas, x, y, z)

			_spawn_surface_detail(x, y, z_surf)
		_water_columns[y] = water_row

	_spawn_shore_reeds(surfaces)
	_spawn_redshirts(surfaces)

func _spawn_shore_reeds(surfaces: Array) -> void:
	if not _water_active:
		return
	var atlas_reed := REED_TILE
	for y in range(H):
		for x in range(W):
			if is_water_column(x, y):
				continue
			if not _adjacent_to_water(x, y):
				continue
			if randf() > REED_SPAWN_CHANCE:
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

func _spawn_redshirts(surfaces: Array) -> void:
	if _redshirt_spawner == null or _atlas_src == null or _atlas_tex == null:
		return
	var placements = _redshirt_spawner.spawn_redshirts(
		Callable(),
		Callable(self, "is_water_column"),
		surfaces,
		W,
		H,
		Z_MAX
	)
	if placements.is_empty():
		return
	var pending: Array[Dictionary] = []
	var positions: Array[Vector2i] = []
	for placement_variant in placements:
		if typeof(placement_variant) != TYPE_DICTIONARY:
			continue
		var placement: Dictionary = placement_variant
		var atlas_xy: Vector2i = placement.get("atlas", Vector2i.ZERO)
		var pos: Vector2i = placement.get("pos", Vector2i.ZERO)
		var flip_h: bool = bool(placement.get("flip_h", false))
		pending.append({
			"atlas": atlas_xy,
			"pos": pos,
			"flip_h": flip_h
		})
		positions.append(pos)
	if pending.is_empty():
		return
	var center_cell := _cluster_center_cell(positions)
	_schedule_redshirt_beam(center_cell, pending, positions, surfaces)

func _schedule_redshirt_beam(center_cell: Vector2i, pending: Array, positions: Array[Vector2i], surfaces: Array) -> void:
	var pending_copy: Array = []
	for entry_variant in pending:
		if entry_variant is Dictionary:
			pending_copy.append((entry_variant as Dictionary).duplicate(true))
	var positions_copy: Array[Vector2i] = []
	for cell_variant in positions:
		positions_copy.append(cell_variant)
	_focus_camera_on_cell(center_cell, BEAM_CAMERA_FOCUS_TIME)
	if BEAM_SPAWN_DELAY <= 0.0:
		_finalize_redshirt_beam(center_cell, pending_copy, positions_copy, surfaces)
		return
	var tree := get_tree()
	if tree == null:
		_finalize_redshirt_beam(center_cell, pending_copy, positions_copy, surfaces)
		return
	var timer := tree.create_timer(BEAM_SPAWN_DELAY)
	timer.timeout.connect(func ():
		_finalize_redshirt_beam(center_cell, pending_copy, positions_copy, surfaces)
	, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

func _finalize_redshirt_beam(center_cell: Vector2i, pending: Array, positions: Array[Vector2i], surfaces: Array) -> void:
	_play_beam_down_effect(center_cell, positions.size())
	var delay: float = max(0.0, BEAM_REDSHIRT_DELAY)
	if delay <= 0.0:
		_spawn_redshirt_batch(pending, center_cell, positions, surfaces)
		return
	var tree := get_tree()
	if tree == null:
		_spawn_redshirt_batch(pending, center_cell, positions, surfaces)
		return
	var timer := tree.create_timer(delay)
	timer.timeout.connect(func ():
		_spawn_redshirt_batch(pending, center_cell, positions, surfaces)
	, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

func _spawn_redshirt_batch(pending: Array, center_cell: Vector2i, positions: Array[Vector2i], surfaces: Array) -> void:
	for entry_variant in pending:
		var entry: Dictionary = entry_variant
		var atlas_xy: Vector2i = entry.get("atlas", Vector2i.ZERO)
		var pos: Vector2i = entry.get("pos", Vector2i.ZERO)
		var flip_h: bool = bool(entry.get("flip_h", false))
		_place_redshirt_sprite(atlas_xy, pos.x, pos.y, flip_h, center_cell, _random_redshirt_radius())
	_camera_centered_by_spawn = true

func _place_redshirt_sprite(
	atlas_xy: Vector2i,
	x: int,
	y: int,
	flip_h: bool,
	wander_center: Vector2i,
	wander_radius: int
) -> void:
	if _atlas_src == null or _atlas_tex == null or draw_root == null:
		return
	var region: Rect2i = _atlas_src.get_tile_texture_region(atlas_xy)
	if region.size == Vector2i.ZERO:
		return
	var agent := RedshirtAgentScript.new()
	var anchor := Vector2(_tile_w * 0.5, _tile_h)
	draw_root.add_child(agent)
	agent.configure(
		self,
		_atlas_tex,
		region,
		Vector2i(x, y),
		anchor,
		REDSHIRT_SORT_BIAS,
		wander_center,
		wander_radius,
		REDSHIRT_MOVE_INTERVAL,
		REDSHIRT_SECONDS_PER_TILE,
		flip_h
	)
	_register_redshirt(agent)
	var tint := agent.modulate
	agent.modulate = Color(tint.r, tint.g, tint.b, 0.0)
	var fade := agent.create_tween()
	fade.tween_property(agent, "modulate:a", 1.0, REDSHIRT_SPAWN_FADE).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)

func _focus_camera_on_cell(center_cell: Vector2i, duration: float) -> void:
	if cam == null:
		return
	var z_top := surface_z_at(center_cell.x, center_cell.y)
	var target := project_iso3d(float(center_cell.x), float(center_cell.y), float(z_top + 1))
	if duration <= 0.0:
		if _camera_focus_tween != null:
			_camera_focus_tween.kill()
			_camera_focus_tween = null
		cam.global_position = target
		_camera_centered_by_spawn = true
		return
	_camera_centered_by_spawn = false
	if _camera_focus_tween != null:
		_camera_focus_tween.kill()
	_camera_focus_tween = cam.create_tween()
	_camera_focus_tween.tween_property(cam, "global_position", target, duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	_camera_focus_tween.finished.connect(func ():
		_camera_centered_by_spawn = true
		_camera_focus_tween = null
	, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

func _cluster_center_cell(cells: Array[Vector2i]) -> Vector2i:
	if cells.is_empty():
		return Vector2i(W >> 1, H >> 1)
	var accum_x := 0.0
	var accum_y := 0.0
	for cell_variant in cells:
		var cell: Vector2i = cell_variant
		accum_x += float(cell.x)
		accum_y += float(cell.y)
	var inv := 1.0 / float(max(1, cells.size()))
	var dims := get_dimensions()
	var cx := clampi(int(round(accum_x * inv)), 0, max(0, dims.x - 1))
	var cy := clampi(int(round(accum_y * inv)), 0, max(0, dims.y - 1))
	return Vector2i(cx, cy)

func _register_redshirt(agent: Node) -> void:
	if agent == null:
		return
	_active_redshirts.append(agent)
	var cleanup := Callable(self, "_on_redshirt_tree_exit").bind(agent)
	if agent.tree_exited.is_connected(cleanup):
		return
	agent.tree_exited.connect(cleanup, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

func _on_redshirt_tree_exit(agent: Node) -> void:
	if _active_redshirts.has(agent):
		_active_redshirts.erase(agent)

func _despawn_redshirts() -> void:
	for agent in _active_redshirts:
		if is_instance_valid(agent):
			agent.queue_free()
	_active_redshirts.clear()

func _play_beam_down_effect(center_cell: Vector2i, count: int) -> void:
	if draw_root == null:
		return
	var z_top := surface_z_at(center_cell.x, center_cell.y)
	var beam_base_pos := project_iso3d(float(center_cell.x), float(center_cell.y), float(z_top + 1))
	var beam := Node2D.new()
	beam.position = beam_base_pos - Vector2(0.0, BEAM_HEIGHT_PX) # anchor so the bottom sits on the ground plane
	beam.z_index = MapUtilsRef.sort_key(center_cell.x, center_cell.y, z_top + 2) + 128
	var poly := Polygon2D.new()
	var width := BEAM_WIDTH_BASE_PX + float(max(0, count - 1)) * BEAM_WIDTH_PER_AGENT_PX
	var half_w := width * 0.5
	poly.polygon = PackedVector2Array([
		Vector2(-half_w, 0.0),
		Vector2(half_w, 0.0),
		Vector2(half_w * 0.5, BEAM_HEIGHT_PX),
		Vector2(-half_w * 0.5, BEAM_HEIGHT_PX),
	])
	poly.modulate = BEAM_COLOR
	poly.antialiased = true
	beam.add_child(poly)
	draw_root.add_child(beam)
	poly.scale = Vector2(0.3, 0.1)
	var shimmer := CPUParticles2D.new()
	shimmer.position = Vector2(0.0, BEAM_HEIGHT_PX * 0.5)
	shimmer.amount = BEAM_COLUMN_PARTICLE_AMOUNT
	shimmer.lifetime = BEAM_DURATION
	shimmer.one_shot = true
	shimmer.preprocess = BEAM_DURATION
	shimmer.direction = Vector2(0.0, -1.0)
	shimmer.spread = 30.0
	shimmer.initial_velocity_min = BEAM_COLUMN_PARTICLE_SPEED * 0.35
	shimmer.initial_velocity_max = BEAM_COLUMN_PARTICLE_SPEED
	shimmer.gravity = Vector2.ZERO
	shimmer.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINTS
	var shimmer_points := PackedVector2Array()
	var segments: int = max(1, BEAM_COLUMN_SEGMENTS)
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var y := t * BEAM_HEIGHT_PX
		shimmer_points.append(Vector2(-half_w, y))
		shimmer_points.append(Vector2(half_w, y))
	shimmer.emission_points = shimmer_points
	shimmer.modulate = Color(BEAM_COLOR.r, BEAM_COLOR.g, BEAM_COLOR.b, 0.8)
	shimmer.emitting = true
	beam.add_child(shimmer)
	var sparks := CPUParticles2D.new()
	sparks.position = Vector2(0.0, BEAM_HEIGHT_PX)
	sparks.amount = BEAM_LANDING_PARTICLE_AMOUNT
	sparks.lifetime = BEAM_LANDING_PARTICLE_LIFETIME
	sparks.one_shot = true
	sparks.preprocess = BEAM_LANDING_PARTICLE_LIFETIME
	sparks.spread = 240.0
	sparks.initial_velocity_min = BEAM_LANDING_PARTICLE_SPEED * 0.5
	sparks.initial_velocity_max = BEAM_LANDING_PARTICLE_SPEED
	sparks.gravity = Vector2(0.0, 420.0)
	sparks.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	sparks.emission_sphere_radius = BEAM_LANDING_PARTICLE_RADIUS
	sparks.modulate = BEAM_COLOR
	sparks.emitting = true
	beam.add_child(sparks)
	var tween := beam.create_tween()
	tween.tween_property(poly, "scale", Vector2(1.0, 1.0), BEAM_DURATION * 0.6).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(poly, "modulate:a", 0.0, BEAM_DURATION * 0.4).set_delay(BEAM_DURATION * 0.3).set_ease(Tween.EASE_IN)
	tween.finished.connect(func ():
		beam.queue_free()
	)

func _random_redshirt_radius() -> int:
	var jitter := (randi_range(-REDSHIRT_WANDER_RADIUS_JITTER, REDSHIRT_WANDER_RADIUS_JITTER) if REDSHIRT_WANDER_RADIUS_JITTER > 0 else 0)
	return max(1, REDSHIRT_WANDER_RADIUS + jitter)

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
	_regenerate_object_layers(true)

# ── Input (R = rebuild) ───────────────────────────────────────────────────────
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		var has_modifier: bool = e.shift_pressed or e.alt_pressed or e.ctrl_pressed or e.meta_pressed
		if new_slice_key != KEY_NONE and e.keycode == new_slice_key and not has_modifier:
			new_slice()
			return
		if e.keycode == KEY_R and not has_modifier:
			_rebuild()
