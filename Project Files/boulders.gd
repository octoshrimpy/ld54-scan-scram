# boulders.gd — Atlas-stacked compound stones (flat cluster at one level)
# Godot 4.5.x
extends TileMapLayer
class_name BoulderGen

signal highlight_clicked(cell: Vector2i, world_position: Vector2, source: StringName)

const MapUtilsRef := preload("res://utils/map_utils.gd")
const TreeOutlineFactoryScript := preload("res://addons/outline/TreeOutlineFactory.gd")
const HoverOutlineSpriteScript := preload("res://addons/outline/hover_outline_sprite.gd")
const BOULDER_SOURCE := &"boulders"

# ───────────────────────── Scene / map wiring ─────────────────────────────────
@export var map_ref: NodePath                    # node with surface_z_at(x,y) and _project_iso3d(x,y,z)
@export var boulders_root: Node2D                # parent for spawned sprites (defaults to self)

# Use this TileMapLayer's TileSet; pick which atlas source to read from
@export var SOURCE_ID: int = 0                   # TileSetAtlasSource id

# Atlas rectangle of stone pieces (inclusive, atlas coords)
@export var tile_min: Vector2i = Vector2i(55, 65)
@export var tile_max: Vector2i = Vector2i(57, 68)

# ───────────────────────────── Outline controls ──────────────────────────────
@export var outline_color: Color = Color(0.92, 0.76, 0.55, 0.85)
@export_range(0, 8, 1) var outline_thickness_px: int = 1
@export_range(0, 16, 1) var outline_padding_px: int = 2
@export var outline_hover_margin_px: float = 0.0
@export var outlines_hover_only: bool = true
@export_range(0.0, 1.0, 0.01) var outline_hover_alpha_threshold: float = 0.65

# World/grid size (cells)
@export var W: int = 20
@export var H: int = 20

# ───────────────────────── Placement parameters ───────────────────────────────
@export var rock_count_min: int = 4              # compounds per regen
@export var rock_count_max: int = 8
@export var spawn_margin_cells: int = 1          # avoid outer border when picking cells
@export var slope_allow: int = 3                 # allow some slope

# Compound cluster (all pieces share the same ground level)
@export var pieces_min: int = 4                  # tiles per compound stone
@export var pieces_max: int = 9
@export var unique_per_compound: bool = true     # ⟵ NEW: do not reuse the same tile in one compound
@export var max_x_jitter_px: int = 10            # keep center within ±8 px (smallest piece is 8×8)
@export var y_jitter_px: int = 3                 # downward jitter to tuck edges (0 = perfectly level; never lifts sprites)

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
var _atlas_image: Image
var _map_cache: Node
var _outline_factory: TreeOutlineFactory
var _occupied_cells: Array[Vector2i] = []

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
	_map_cache = _resolve_map()

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
	_atlas_image = _atlas_tex.get_image() if _atlas_tex != null else null
	if _atlas_image != null and _atlas_image.is_compressed():
		var err := _atlas_image.decompress()
		if err != OK:
			push_warning("BoulderGen: failed to decompress atlas image (%s)." % str(err))
			_atlas_image = null
	_outline_factory = TreeOutlineFactoryScript.new()
	_place_boulders()

func _configure_outline_factory() -> void:
	if _outline_factory == null:
		_outline_factory = TreeOutlineFactoryScript.new()
	_outline_factory.outline_color = outline_color
	_outline_factory.outline_thickness_px = outline_thickness_px
	_outline_factory.padding_px = outline_padding_px
	_outline_factory.hover_margin_px = outline_hover_margin_px
	_outline_factory.hover_only = outlines_hover_only
	_outline_factory.hover_alpha_threshold = outline_hover_alpha_threshold

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

func regenerate_boulders(reseed: bool = false) -> void:
	if reseed:
		_rng.seed = int(Time.get_ticks_usec())
		_place_boulders()
	else:
		_regenerate_boulders()

func set_seed(new_seed: int) -> void:
	_rng.seed = new_seed

func set_tile_region(min_corner: Vector2i, max_corner: Vector2i) -> void:
	tile_min = min_corner
	tile_max = max_corner

# ───────────────────────── Placement entrypoint ───────────────────────────────
func _place_boulders() -> void:
	_clear_existing()
	_occupied_cells.clear()

	# Collect all valid surface columns within margin
	var half: int = (min(W, H)) >> 1
	var margin: int = clampi(spawn_margin_cells, 0, half)
	var columns: Array[Vector2i] = []
	for y in range(margin, H - margin):
		for x in range(margin, W - margin):
			if MapUtilsRef.column_has_water(_map_cache, x, y):
				continue
			if _is_flat_enough(x, y, slope_allow) and _map_surface_z(x, y) >= 0:
				columns.append(Vector2i(x, y))

	if columns.is_empty():
		push_warning("BoulderGen: no valid surface columns to place stones.")
		return

	_shuffle_array(columns)
	var want: int = clampi(_rng.randi_range(rock_count_min, rock_count_max), 0, columns.size())
	for i in range(want):
		var cell: Vector2i = columns[i]
		var z: int = _map_surface_z(cell.x, cell.y)
		var base_pos: Vector2 = _column_bottom_world(cell.x, cell.y, z) # bottom-center of column
		_spawn_compound_at_world(base_pos, cell, z)
	_publish_obstacles()

# Remove previously spawned compounds
func _clear_existing() -> void:
	for c in boulders_root.get_children():
		if c is HoverOutlineSprite:
			c.queue_free()

# ───────────────────────── Compound stone (flat cluster) ──────────────────────
func _spawn_compound_at_world(bottom_center: Vector2, cell: Vector2i, z: int) -> void:
	if _atlas_src == null or _atlas_tex == null:
		return
	_occupied_cells.append(cell)

	var all_tiles: Array[Vector2i] = _valid_tiles_in_rect(tile_min, tile_max)
	if all_tiles.is_empty():
		return
	_shuffle_array(all_tiles)

	var desired: int = clampi(_rng.randi_range(pieces_min, pieces_max), 1, 512)
	var count: int = desired
	if unique_per_compound:
		count = min(desired, all_tiles.size())

	var center_x: float = bottom_center.x
	var ground_y: float = bottom_center.y
	var compound_z := MapUtilsRef.sort_key(cell.x, cell.y, z + rock_z_offset)

	var temp_group := Node2D.new()
	temp_group.visible = false
	temp_group.z_index = compound_z
	temp_group.z_as_relative = false
	boulders_root.add_child(temp_group)

	for i in range(count):
		var tile_xy: Vector2i
		if unique_per_compound:
			tile_xy = all_tiles[i]                      # unique pick (pool is shuffled)
		else:
			# allow repeats
			tile_xy = all_tiles[_rng.randi_range(0, all_tiles.size() - 1)]

		if not _atlas_src.has_tile(tile_xy):
			continue
		var region: Rect2i = _atlas_src.get_tile_texture_region(tile_xy)
		if region.size == Vector2i.ZERO:
			continue

		var w: int = region.size.x
		var h: int = region.size.y

		# Jitters: keep bottoms at same ground level; vertical jitter only sinks stones to avoid floating.
		var jx: int = _rng.randi_range(-max_x_jitter_px, max_x_jitter_px)
		var jy: int = (_rng.randi_range(0, y_jitter_px) if y_jitter_px > 0 else 0)

		var spr := Sprite2D.new()
		spr.texture = _atlas_tex
		spr.region_enabled = true
		spr.region_rect = Rect2(region.position, region.size)
		spr.centered = false
		spr.texture_filter = rock_filter
		spr.z_as_relative = false
		spr.z_index = compound_z
		temp_group.add_child(spr)

		# Place: align piece bottom to the same ground level (compound = flat cluster)
		var px: float = center_x + float(jx) - float(w) * 0.5
		var py: float = ground_y - float(h) + float(jy)
		var p := (Vector2(px, py).floor() if pixel_snap else Vector2(px, py))
		spr.global_position = p

	_configure_outline_factory()
	var meta := {
		"cell": cell,
		"world": bottom_center,
		"source": BOULDER_SOURCE
	}
	var hover_sprite := _outline_factory.bake_group(temp_group, _atlas_image, boulders_root, compound_z, meta)
	if hover_sprite != null:
		var cb := Callable(self, "_on_hover_outline_clicked")
		if not hover_sprite.outline_clicked.is_connected(cb):
			hover_sprite.outline_clicked.connect(cb, CONNECT_REFERENCE_COUNTED)

func _publish_obstacles() -> void:
	var map := _get_map()
	if map == null:
		return
	if not map.has_method("register_obstacle_cells"):
		return
	var payload: Array[Vector2i] = []
	for cell_variant in _occupied_cells:
		var c: Vector2i = cell_variant
		payload.append(c)
	map.call("register_obstacle_cells", BOULDER_SOURCE, payload)

func _on_hover_outline_clicked(metadata: Dictionary) -> void:
	var cell_variant: Variant = metadata.get("cell", Vector2i.ZERO)
	var world_variant: Variant = metadata.get("world", Vector2.ZERO)
	var source_variant: Variant = metadata.get("source", BOULDER_SOURCE)
	var cell: Vector2i = Vector2i.ZERO
	if cell_variant is Vector2i:
		cell = cell_variant
	var world: Vector2 = Vector2.ZERO
	if world_variant is Vector2:
		world = world_variant
	var source: StringName = BOULDER_SOURCE
	if source_variant is StringName:
		source = source_variant
	emit_signal("highlight_clicked", cell, world, source)

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

func _valid_tiles_in_rect(p0: Vector2i, p1: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for tile_xy in _tiles_in_rect(p0, p1):
		if _atlas_src != null and _atlas_src.has_tile(tile_xy):
			out.append(tile_xy)
	return out

func _shuffle_array(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var temp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = temp

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

func _column_bottom_world(x: int, y: int, z: int) -> Vector2:
	var map := _get_map()
	var pos := MapUtilsRef.column_bottom_world(map, x, y, z)
	return pos if map != null else global_position

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
