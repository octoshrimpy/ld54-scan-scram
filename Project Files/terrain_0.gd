# TerrainGen.gd — Single-file isometric terrain generator for TileMapLayer "Terrain0"
# - Elevation bands (Noise B + profile) + local variation (Noise A + octaves)
# - Devool "two-steps-up" visual stacking in a single TileMapLayer
# - Optional water line
# - Optional ramps placed where Δh == 1
# - Auto-collision ring using your EMPTY tile (with physics shape) around drawn tiles
#
# Attach this script to the isometric TileMapLayer (named Terrain0).
# Editor setup expected:
#   • TileMapLayer: y_sort_enabled = true, Texture Filter = Nearest (for pixel art)
#   • TileSet: Shape = Isometric, Tile Size e.g. (16, 8), ramps have z_index = 1
#   • EMPTY tile has a Physics Layer shape

extends TileMapLayer

# ── Map size ─────────────────────────────────────────────────────────────────
@export var width: int = 40
@export var height: int = 40

# ── Tile atlas references (source 0 by default) ──────────────────────────────
@export var source_id: int = 0
@export var atlas_block: Vector2i       = Vector2i(6, 30)   # main solid block (dirt)
@export var atlas_water: Vector2i       = Vector2i(32, 23)  # water surface
@export var atlas_ramp_left: Vector2i   = Vector2i(8, 30)   # using same ramp for both orientations
@export var atlas_ramp_right: Vector2i  = Vector2i(8, 30)   # (adjust if you add a second ramp tile)
@export var atlas_empty: Vector2i       = Vector2i(18, 0)   # EMPTY w/ physics (set to your real empty if not 0,0)

# Optional grass carpet overlay (set to (-1,-1) to disable)
@export var atlas_grass_carpet: Vector2i = Vector2i(2, 21)
@export var carpet_chance: float = 0.35   # 35% chance on tops

# ── Elevation & water ────────────────────────────────────────────────────────
@export var water_level: int = 0        # h <= this => water surface
@export var small_var_amp: float = 6.0  # amplitude from Noise A, in “levels”
@export var two_step_visual: int = 2    # Devool trick: 2 cells up per elevation

# Noise A (octaves) — small organic variation (detail)
@export var a_frequency: float = 0.08
@export var a_octaves: int = 4
@export var a_gain: float = 0.5
@export var a_lacunarity: float = 2.0

# Noise B — band selector for height profile (big shapes)
@export var b_frequency: float = 0.02
@export var b_octaves: int = 3
@export var b_gain: float = 0.5
@export var b_lacunarity: float = 2.0

# Height profile bands: choose baseline by Noise B value in [min,max)
# Example bands (tweak freely)
@export var profile_bands := [
	{"min": 0.00, "max": 0.25, "base": -10},
	{"min": 0.25, "max": 0.58, "base":   5},
	{"min": 0.58, "max": 0.60, "base":  25},
	{"min": 0.60, "max": 1.01, "base":   7},
]

# Ramps & collision ring toggles
@export var place_ramps: bool = true
@export var build_collision_ring: bool = true

# ── Internals ────────────────────────────────────────────────────────────────
var _noiseA: FastNoiseLite = FastNoiseLite.new()
var _noiseB: FastNoiseLite = FastNoiseLite.new()
var _max_h: int = 0                       # maximum elevation found
var _hmap: PackedInt32Array               # flattened heights (y * width + x)

func _ready() -> void:
	y_sort_enabled = true
	_configure_noise(_noiseA, a_frequency, a_octaves, a_gain, a_lacunarity)
	_configure_noise(_noiseB, b_frequency, b_octaves, b_gain, b_lacunarity)
	_generate()

# ── Noise helpers ────────────────────────────────────────────────────────────
func _configure_noise(n: FastNoiseLite, f: float, o: int, g: float, l: float) -> void:
	n.noise_type = FastNoiseLite.TYPE_PERLIN
	n.frequency = f
	n.fractal_octaves = o
	n.fractal_gain = g
	n.fractal_lacunarity = l
	n.seed = randi()

func _noise01(n: FastNoiseLite, x: float, y: float) -> float:
	return 0.5 + 0.5 * n.get_noise_2d(x, y) # map [-1,1] → [0,1]

# ── Height profile ───────────────────────────────────────────────────────────
func _profile_base(v01: float) -> int:
	for band in profile_bands:
		if v01 >= float(band.min) and v01 < float(band.max):
			return int(band.base)
	return 0

# ── Generation ───────────────────────────────────────────────────────────────
func _generate() -> void:
	clear()

	# Build heightmap
	_hmap = PackedInt32Array()
	_hmap.resize(width * height)
	_max_h = -1_000_000
	var min_h: int = 1_000_000

	for y in range(height):
		for x in range(width):
			var vb: float = _noise01(_noiseB, x, y)      # big shapes band selector
			var base: int = _profile_base(vb)
			var va: float = _noise01(_noiseA, x, y)      # local detail
			var detail: int = int(round((va - 0.5) * 2.0 * small_var_amp))
			var h: int = base + detail
			_hmap[y * width + x] = h
			if h > _max_h: _max_h = h
			if h < min_h:  min_h = h

	# Offset rows upward so we never write negative y
	var y_base: int = two_step_visual * max(0, _max_h) + 4

	# Pass 1: draw terrain columns (blocks or water surface)
	for y in range(height):
		for x in range(width):
			var h: int = _hmap[y * width + x]

			if atlas_water != Vector2i(-1, -1) and h <= water_level:
				var wy: int = y_base + y - two_step_visual * water_level
				_set_tile(Vector2i(x, wy), atlas_water)
			elif h > water_level:
				for k in range(water_level + 1, h + 1):
					var ry: int = y_base + y - two_step_visual * k
					_set_tile(Vector2i(x, ry), atlas_block)

	# Pass 2 (optional): ramps where Δh == 1 to smooth edges
	if place_ramps:
		_place_ramps(y_base)

	# Pass 3: collision ring (EMPTY tile with physics)
	if build_collision_ring:
		_build_collision_ring()

# Set a tile at cell with given atlas (source is configurable)
func _set_tile(cell: Vector2i, atlas: Vector2i) -> void:
	set_cell(cell, source_id, atlas, 0)

# ── Ramp placement ───────────────────────────────────────────────────────────
func _place_ramps(y_base: int) -> void:
	# Simple 4-neighbor rule: if neighbor is exactly 1 higher,
	# place a ramp on the lower side at the higher cell's elevation row.
	for y in range(height):
		for x in range(width):
			var h: int = _hmap[y * width + x]

			# left neighbor (x-1, y)
			if x > 0:
				var hl: int = _hmap[y * width + (x - 1)]
				if hl == h + 1:
					var cy: int = y_base + y - two_step_visual * (h + 1)
					_set_tile(Vector2i(x, cy), atlas_ramp_left)
			# right neighbor (x+1, y)
			if x < width - 1:
				var hr: int = _hmap[y * width + (x + 1)]
				if hr == h + 1:
					var cy: int = y_base + y - two_step_visual * (h + 1)
					_set_tile(Vector2i(x, cy), atlas_ramp_right)
			# up neighbor (x, y-1)
			if y > 0:
				var hu: int = _hmap[(y - 1) * width + x]
				if hu == h + 1:
					var cy: int = y_base + y - two_step_visual * (h + 1)
					_set_tile(Vector2i(x, cy), atlas_ramp_left)  # adjust to match your art
			# down neighbor (x, y+1)
			if y < height - 1:
				var hd: int = _hmap[(y + 1) * width + x]
				if hd == h + 1:
					var cy: int = y_base + y - two_step_visual * (h + 1)
					_set_tile(Vector2i(x, cy), atlas_ramp_right)

# ── Devool-style automatic collision ring (EMPTY tile) ───────────────────────
func _build_collision_ring() -> void:
	if tile_set == null:
		push_warning("TerrainGen: TileSet is null; cannot build collision ring.")
		return

	var used: PackedVector2Array = get_used_cells()
	if used.is_empty():
		return

	var placed := {}
	for cell in used:
		for n in _neighbors_8(cell):
			if get_cell_source_id(n) != -1:
				continue
			set_cell(n, source_id, atlas_empty, 0)
			placed[n] = true

	# Optional tighten pass
	for cell in placed.keys():
		for n in _neighbors_8(cell):
			if get_cell_source_id(n) == -1:
				set_cell(n, source_id, atlas_empty, 0)

func _neighbors_8(c: Vector2i) -> Array[Vector2i]:
	return [
		c + Vector2i( 1,  0), c + Vector2i(-1,  0),
		c + Vector2i( 0,  1), c + Vector2i( 0, -1),
		c + Vector2i( 1,  1), c + Vector2i( 1, -1),
		c + Vector2i(-1,  1), c + Vector2i(-1, -1),
	]

# ── input (R = rebuild) ───────────────────────────────────────────────────────
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_R:
				_generate()

