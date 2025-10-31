# boulders.gd — Atlas-stacked compound stones (flat cluster at one level)
# Godot 4.5.x
extends TileMapLayer
class_name BoulderGen

# ───────────────────────── Scene / map wiring ─────────────────────────────────
@export var map_ref: NodePath                    # node with surface_z_at(x,y) and _project_iso3d(x,y,z)
@export var boulders_root: Node2D                # parent for spawned sprites (defaults to self)

# Use this TileMapLayer's TileSet; pick which atlas source to read from
@export var SOURCE_ID: int = 0                   # TileSetAtlasSource id

# Atlas rectangle of stone pieces (inclusive, atlas coords)
@export var tile_min: Vector2i = Vector2i(55, 65)
@export var tile_max: Vector2i = Vector2i(57, 68)

# World/grid size (cells)
@export var W: int = 20
@export var H: int = 20

# ───────────────────────── Placement parameters ───────────────────────────────
@export var rock_count_min: int = 2              # compounds per regen
@export var rock_count_max: int = 3
@export var spawn_margin_cells: int = 1          # avoid outer border when picking cells
@export var slope_allow: int = 3                 # allow some slope

# Compound cluster (all pieces share the same ground level)
@export var pieces_min: int = 3                  # tiles per compound stone
@export var pieces_max: int = 7
@export var unique_per_compound: bool = true     # ⟵ NEW: do not reuse the same tile in one compound
@export var max_x_jitter_px: int = 8             # keep center within ±8 px (smallest piece is 8×8)
@export var y_jitter_px: int = 2                 # small ±y jitter to interleave edges (0 = perfectly level)

# Sorting
@export var rock_z_offset: int = 4               # above terrain at column

# Filtering / pixel snap
@export var rock_filter: CanvasItem.TextureFilter = CanvasItem.TEXTURE_FILTER_NEAREST
@export var pixel_snap: bool = true              # ⟵ NEW: snap sprite positions to whole pixels

# Hotkey
@export var regenerate_key: int = KEY_B
@export var regen_action: StringName = &"regen_boulders"
@export var reseed_on_regen: bool = true

# ───────────────────────── Internal state ─────────────────────────────────────
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _atlas_src: TileSetAtlasSource
var _atlas_tex: Texture2D

# ───────────────────────── Lifecycle ──────────────────────────────────────────
func _enter_tree() -> void:
	# Ensure the action exists as early as possible
	if not InputMap.has_action(regen_action):
		InputMap.add_action(regen_action)
		var ev := InputEventKey.new()
		ev.keycode = regenerate_key as Key
		InputMap.action_add_event(regen_action, ev)

func _ready() -> void:
	if boulders_root == null:
		boulders_root = self

	_rng.randomize()

	# Resolve atlas source/texture from THIS TileMapLayer's TileSet
	if tile_set == null:
		push_warning("BoulderGen: this TileMapLayer has no TileSet.")
		return
	_atlas_src = tile_set.get_source(SOURCE_ID) as TileSetAtlasSource
	if _atlas_src == null:
		push_warning("BoulderGen: TileSet source id %d is not a TileSetAtlasSource." % SOURCE_ID)
		return
	_atlas_tex = _atlas_src.texture
	if _atlas_tex == null:
		push_warning("BoulderGen: Atlas source has no texture.")
		return

func _unhandled_input(e: InputEvent) -> void:
	# Prefer named action…
	if InputMap.has_action(regen_action) and Input.is_action_just_pressed(regen_action):
		_regenerate_boulders()
		return
	# …fallback to raw key if action not registered for any reason.
	if e is InputEventKey and e.pressed and not e.echo:
		if e.keycode == (regenerate_key as Key) or e.physical_keycode == (regenerate_key as Key):
			_regenerate_boulders()

func _regenerate_boulders() -> void:
	if reseed_on_regen:
		_rng.seed = int(Time.get_ticks_usec())
	_place_boulders()

# ───────────────────────── Placement entrypoint ───────────────────────────────
func _place_boulders() -> void:
	_clear_existing()

	# Collect all valid surface columns within margin
	var half: int = (min(W, H)) >> 1
	var margin: int = clampi(spawn_margin_cells, 0, half)
	var columns: Array[Vector2i] = []
	for y in range(margin, H - margin):
		for x in range(margin, W - margin):
			if _is_flat_enough(x, y, slope_allow) and _map_surface_z(x, y) >= 0:
				columns.append(Vector2i(x, y))

	if columns.is_empty():
		push_warning("BoulderGen: no valid surface columns to place stones.")
		return

	columns.shuffle()
	var want: int = clampi(_rng.randi_range(rock_count_min, rock_count_max), 0, columns.size())
	for i in range(want):
		var cell: Vector2i = columns[i]
		var z: int = _map_surface_z(cell.x, cell.y)
		var base_pos: Vector2 = _column_bottom_world(cell.x, cell.y, z) # bottom-center of column
		_spawn_compound_at_world(base_pos, cell, z)

# Remove previously spawned compounds
func _clear_existing() -> void:
	for c in boulders_root.get_children():
		if c is Sprite2D and c.has_meta("is_boulder"):
			c.queue_free()

# ───────────────────────── Compound stone (flat cluster) ──────────────────────
func _spawn_compound_at_world(bottom_center: Vector2, cell: Vector2i, z: int) -> void:
	if _atlas_src == null or _atlas_tex == null:
		return

	var all_tiles: Array[Vector2i] = _tiles_in_rect(tile_min, tile_max) # inclusive rectangle
	if all_tiles.is_empty():
		return
	all_tiles.shuffle()

	var desired: int = clampi(_rng.randi_range(pieces_min, pieces_max), 1, 512)
	var count: int = desired
	if unique_per_compound:
		count = min(desired, all_tiles.size())

	var center_x: float = bottom_center.x
	var ground_y: float = bottom_center.y

	for i in range(count):
		var tile_xy: Vector2i
		if unique_per_compound:
			tile_xy = all_tiles[i]                      # unique pick (pool is shuffled)
		else:
			# allow repeats
			tile_xy = all_tiles[_rng.randi_range(0, all_tiles.size() - 1)]

		var region: Rect2i = _atlas_src.get_tile_texture_region(tile_xy)
		if region.size == Vector2i.ZERO:
			continue

		var w: int = region.size.x
		var h: int = region.size.y

		# Jitters: keep bottoms at same ground level; small ±y to tuck edges if desired.
		var jx: int = _rng.randi_range(-max_x_jitter_px, max_x_jitter_px)
		var jy: int = (_rng.randi_range(-y_jitter_px, y_jitter_px) if y_jitter_px > 0 else 0)

		var spr := Sprite2D.new()
		spr.texture = _atlas_tex
		spr.region_enabled = true
		spr.region_rect = Rect2(region.position, region.size)
		spr.centered = false
		spr.texture_filter = rock_filter
		spr.z_as_relative = false
		spr.z_index = _sort_key(cell.x, cell.y, z + rock_z_offset)
		spr.set_meta("is_boulder", true)
		boulders_root.add_child(spr)

		# Place: align piece bottom to the same ground level (compound = flat cluster)
		var px: float = center_x + float(jx) - float(w) * 0.5
		var py: float = ground_y - float(h) + float(jy)
		var p := (Vector2(px, py).floor() if pixel_snap else Vector2(px, py))
		spr.global_position = p

# ───────────────────────── Helpers: atlas tiles & map ─────────────────────────
func _tiles_in_rect(p0: Vector2i, p1: Vector2i) -> Array[Vector2i]:
	var x0: int = min(p0.x, p1.x)
	var y0: int = min(p0.y, p1.y)
	var x1: int = max(p0.x, p1.x)
	var y1: int = max(p0.y, p1.y)
	var out: Array[Vector2i] = []
	for ty in range(y0, y1 + 1):
		for tx in range(x0, x1 + 1):
			out.append(Vector2i(tx, ty))
	return out

func _get_map() -> Node:
	return get_node_or_null(map_ref)

func _map_surface_z(x: int, y: int) -> int:
	var m := _get_map()
	if m == null or not m.has_method("surface_z_at"):
		return -1
	return int(m.call("surface_z_at", x, y))

func _column_bottom_world(x: int, y: int, z: int) -> Vector2:
	var m := _get_map()
	if m != null and m.has_method("_project_iso3d"):
		return Vector2(m.call("_project_iso3d", float(x), float(y), float(z)))
	return global_position

static func _sort_key(x: int, y: int, z: int) -> int:
	return y * 128 + x * 4 + z

func _is_flat_enough(x: int, y: int, allow: int) -> bool:
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
	return max(dzx, dzy) <= allow
