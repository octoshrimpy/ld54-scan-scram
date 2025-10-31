# map.gd — 20x20x(Z_MAX+1) cube rendered with per-tile Sprite2D (true elevation)
# Godot 4.5.1 (TileMapLayer only used as atlas/grid source; hidden)
# - FIX: Z step is now configurable; default 16 px per layer
# - Option: position in TileMap grid space (USE_TILEMAP_GRID) or pure iso math
# - Compact z_index, global Z; no YSort conflicts

extends Node2D

# ── Scene refs ────────────────────────────────────────────────────────────────
@onready var cam: Camera2D = $Camera2D
@onready var terrain_root: Node = $"terrain"  # only to access TileSet/atlas/grid

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
const CHUNKS_X: int   = 7
const CHUNKS_Y: int   = 7
const SLICE:   int    = 4              # 5*4 = 20
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

# ── Gaussian heightmap over (x,y) → z_surf ────────────────────────────────────
const HEIGHT_FREQ: float = 0.05
const HEIGHT_OCTAVES: int      = 3
const HEIGHT_GAIN: float       = 0.55
const HEIGHT_LACUN: float      = 2.0
const HEIGHT_BASELINE_T: float = 0.65
const HEIGHT_SIGMA: float      = 2.0
const HEIGHT_GAUSS_CLAMP: float = 2.5

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
const FAM_STONE := "gray-brown"
const FAM_DIRT  := "brown"
const FAM_GRASS := "emerald"

# ── water atlas (absolute atlas coords) ───────────────────────────────────────
const WATER_ATLAS := Vector2i(54, 36)

# ── noise fields ──────────────────────────────────────────────────────────────
var top_noise: FastNoiseLite     = FastNoiseLite.new()
var carpet_noise: FastNoiseLite  = FastNoiseLite.new()
var grad_noise: FastNoiseLite    = FastNoiseLite.new()
var height_u1: FastNoiseLite     = FastNoiseLite.new()
var height_u2: FastNoiseLite     = FastNoiseLite.new()
var rng_seed: int = 0

# ── cached atlas source / metrics ─────────────────────────────────────────────
var _atlas_src: TileSetAtlasSource
var _atlas_tex: Texture2D
var _tile_w := 16.0
var _tile_h := 8.0
var _base_tm: TileMapLayer

# ── lifecycle ─────────────────────────────────────────────────────────────────
func _ready() -> void:
	randomize()
	_collect_layers()
	_setup_draw_root()
	_setup_noises()
	_bind_atlas_source()
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
static func _sort_key(x: int, y: int, z: int) -> int:
	# y dominates, then x, then z (higher z draws last/on top)
	return y * 128 + x * 4 + z

func _project_iso3d(x: float, y: float, z: float) -> Vector2:
	if USE_TILEMAP_GRID and _base_tm != null:
		# Use TileMap grid; map_to_local returns the cell's draw origin.
		var cell_pos := _base_tm.map_to_local(Vector2i(x, y))
		return cell_pos - Vector2(0, float(Z_STEP_PX) * z)
	else:
		# Pure diamond iso math based on tile size
		var sx := (x - y) * (_tile_w * 0.5)
		var sy := (x + y) * (_tile_h * 0.5) - z * float(Z_STEP_PX)
		return Vector2(sx, sy)

func _place_sprite(atlas_xy: Vector2i, x: int, y: int, z: int, tint: Color = Color(1,1,1,1)) -> void:
	if _atlas_src == null or _atlas_tex == null:
		return
	var region: Rect2i = _atlas_src.get_tile_texture_region(atlas_xy)
	if region.size == Vector2i.ZERO:
		return
	var sp := Sprite2D.new()
	sp.texture = _atlas_tex
	sp.region_enabled = true
	sp.region_rect = Rect2(region.position, region.size)

	var p := _project_iso3d(float(x), float(y), float(z))

	# Anchor so the diamond sits correctly; TileMap grid origin matches this offset.
	# (If your atlas differs, tweak these two numbers.)
	var anchor := Vector2(_tile_w * 0.5, _tile_h)
	sp.position = p - anchor
	sp.centered = false
	sp.z_as_relative = false
	sp.z_index = _sort_key(x, y, z)
	sp.modulate = tint
	draw_root.add_child(sp)

# ── atlas helpers → atlas coords ──────────────────────────────────────────────
func _family_base(fam: String) -> Vector2i:
	return (FAMILIES.get(fam, FAMILIES["teal"]) as Vector2i)

func _stone_atlas() -> Vector2i:
	var rel: Vector2i = GROUPS["stone"]["rel"]
	return _family_base(FAM_STONE) + rel + Vector2i(0, 1)

func _dirt_atlas() -> Vector2i:
	var rel: Vector2i = GROUPS["dirt"]["rel"]
	var size: Vector2i = GROUPS["dirt"]["size"]
	return _family_base(FAM_DIRT) + Vector2i(rel.x + size.x - 1, rel.y + 1)

func _grassy_dirt_atlas() -> Vector2i:
	var rel: Vector2i = GROUPS["grassy_dirt"]["rel"]
	return _family_base(FAM_GRASS) + rel + Vector2i(0, 1)

func _grass_blade_atlas() -> Vector2i:
	var rel: Vector2i = GROUPS["grass"]["rel"]
	var size: Vector2i = GROUPS["grass"]["size"]
	return _family_base(FAM_GRASS) + rel + Vector2i(randi_range(0, size.x - 1), 3)

func _water_atlas() -> Vector2i:
	return WATER_ATLAS

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

	for n in [height_u1, height_u2]:
		n.noise_type         = FastNoiseLite.TYPE_PERLIN
		n.frequency          = HEIGHT_FREQ
		n.fractal_octaves    = HEIGHT_OCTAVES
		n.fractal_gain       = HEIGHT_GAIN
		n.fractal_lacunarity = HEIGHT_LACUN

# ── height helpers ────────────────────────────────────────────────────────────
func surface_z_at(x: int, y: int) -> int:
	return _surface_z_at(x, y)

func _surface_z_at(x: int, y: int) -> int:
	var u1: float = 0.5 + 0.5 * height_u1.get_noise_2d(float(x), float(y))
	var u2: float = 0.5 + 0.5 * height_u2.get_noise_2d(float(x), float(y))
	u1 = clampf(u1, 1e-6, 1.0 - 1e-6)
	u2 = clampf(u2, 1e-6, 1.0 - 1e-6)
	var g: float = sqrt(-2.0 * log(u1)) * cos(2.0 * PI * u2) # ~N(0,1)
	g = clampf(g, -HEIGHT_GAUSS_CLAMP, HEIGHT_GAUSS_CLAMP)
	var baseline: float = clampf(HEIGHT_BASELINE_T * float(Z_MAX), 0.0, float(Z_MAX))
	var zf: float = baseline + g * HEIGHT_SIGMA
	return clampi(int(round(zf)), 0, Z_MAX)

# ── rebuild ───────────────────────────────────────────────────────────────────
func _clear_drawables() -> void:
	if not draw_root:
		return
	for c in draw_root.get_children():
		c.queue_free()

func _center_camera_on_middle() -> void:
	var cx := W >> 1
	var cy := H >> 1
	var cz := surface_z_at(cx, cy)
	var p := _project_iso3d(cx, cy, cz)
	cam.global_position = p

func _rebuild(new_seed: int = -1) -> void:
	_clear_drawables()
	rng_seed = (new_seed if new_seed != -1 else randi())
	top_noise.seed     = rng_seed ^ 0xABCDEF01
	carpet_noise.seed  = rng_seed ^ 0xBADC0DED
	grad_noise.seed    = rng_seed ^ 0x13579BDF
	height_u1.seed     = rng_seed ^ 0x0F0F0F0F
	height_u2.seed     = rng_seed ^ 0xF00DFACE
	_spawn_cube_terrain()
	_center_camera_on_middle()

# ── main build (per-column surface, fill below, water where air≤sea) ──────────
const SEA_Z := 0

func _spawn_cube_terrain() -> void:
	var atlas_stone := _stone_atlas()
	var atlas_dirt  := _dirt_atlas()
	var atlas_grass := _grassy_dirt_atlas()
	var atlas_water := _water_atlas()

	for y in range(H):
		for x in range(W):
			var z_surf: int = _surface_z_at(x, y)

			# Water where air ≤ sea
			for z in range(0, SEA_Z + 1):
				if z > z_surf:
					_place_sprite(atlas_water, x, y, z)

			# Top cell
			var n_grass: float = 0.5 + 0.5 * top_noise.get_noise_2d(float(x), float(y))
			if n_grass > TOP_PERLIN_THRESH:
				_place_sprite(atlas_grass, x, y, z_surf)
				var n_carpet: float = 0.5 + 0.5 * carpet_noise.get_noise_2d(float(x), float(y))
				if n_carpet > CARPET_PERLIN_THRESH and z_surf + 1 <= Z_MAX:
					_place_sprite(_grass_blade_atlas(), x, y, z_surf + 1)
			else:
				_place_sprite(atlas_dirt, x, y, z_surf)

			# Dirt cap
			for z in range(max(0, z_surf - DIRT_CAP_LAYERS), z_surf):
				_place_sprite(atlas_dirt, x, y, z)

			# Gradient region 0..below cap
			var grad_top: int = max(0, z_surf - DIRT_CAP_LAYERS - 1)
			for z in range(0, grad_top + 1):
				var base_p: float = float(z) / float(max(1, grad_top)) + GRADIENT_BIAS
				var jitter: float = GRADIENT_NOISE_AMPL * (0.5 + 0.5 * grad_noise.get_noise_2d(float(x), float(y)))
				var p_dirt: float = clampf(base_p + (jitter - GRADIENT_NOISE_AMPL * 0.5), 0.0, 1.0)
				var atlas := (atlas_dirt if randf() < p_dirt else atlas_stone)
				_place_sprite(atlas, x, y, z)

			_coastline_rim(x, y, z_surf)

# Thin rim highlight on coasts
func _coastline_rim(x: int, y: int, z_surf: int) -> void:
	if z_surf < SEA_Z:
		return
	var n_water := false
	if x > 0 and surface_z_at(x - 1, y) < SEA_Z: n_water = true
	if x < W - 1 and surface_z_at(x + 1, y) < SEA_Z: n_water = true
	if y > 0 and surface_z_at(x, y - 1) < SEA_Z: n_water = true
	if y < H - 1 and surface_z_at(x, y + 1) < SEA_Z: n_water = true
	if not n_water:
		return

	var atlas_xy := _grassy_dirt_atlas()
	if _atlas_src == null or _atlas_tex == null:
		return
	var region: Rect2i = _atlas_src.get_tile_texture_region(atlas_xy)
	if region.size == Vector2i.ZERO:
		return
	var sp := Sprite2D.new()
	sp.texture = _atlas_tex
	sp.region_enabled = true
	sp.region_rect = Rect2(region.position, region.size)
	sp.scale = Vector2(1.0, 0.06)
	sp.modulate = Color(1.0, 1.0, 0.85, 0.85)
	var p := _project_iso3d(float(x), float(y), float(z_surf))
	var anchor := Vector2(_tile_w * 0.5, _tile_h)
	sp.position = p - Vector2(anchor.x, anchor.y * 0.75)  # sit slightly above top face
	sp.centered = false
	sp.z_as_relative = false
	sp.z_index = _sort_key(x, y, max(z_surf, SEA_Z))
	draw_root.add_child(sp)

# ── Input (R = rebuild) ───────────────────────────────────────────────────────
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_R:
				_rebuild()
