# trees.gd — TreeGen: groves → trees (trunk/branches/leaves) with per-tree outline bake
# Godot 4.5.x
extends Node2D

const TreeOutlineFactory := preload("res://addons/outline/TreeOutlineFactory.gd")

# ───────────────────────────────── Scene/atlas refs ───────────────────────────
@export var atlas_layer: TileMapLayer
@export var trunks_root: Node2D
@export var map_ref: NodePath

# ─────────────────────────── World/grid size (cells) ──────────────────────────
@export var W: int = 20
@export var H: int = 20
@export var SOURCE_ID: int = 0

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

# ─────────────────────────── Internal caches / state ─────────────────────────
var _atlas_src: TileSetAtlasSource
var _atlas_tex: Texture2D

# per-tree (mutates as we build each tree)
var _trunk_total_px: int = 48
var _trunk_width_px: int = 5

# helper records
class GroundSpawn:
	var position: Vector2
	var cell: Vector2i
	var z: int

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
	if trunks_root == null:
		trunks_root = self
	_regenerate_forest()

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_Y: _regenerate_forest()

# ───────────────────────────── Forest regen ───────────────────────────────────
func _regenerate_forest() -> void:
	# Clear previous baked sprites (and any leftovers)
	for c in trunks_root.get_children():
		if c is Sprite2D or c is Node2D:
			c.queue_free()

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

	# Plan groves (strict → relaxed)
	var groves: Array[Grove] = _plan_groves(grove_spacing_cells, slope_max, require_grass_top, max_spawn_attempts)
	if groves.is_empty() and allow_relaxed_retry:
		groves = _plan_groves(max(1, int(grove_spacing_cells * 0.6)), slope_max + 2, false, int(max_spawn_attempts * 1.5))

	# Fallback grove
	if groves.is_empty():
		push_warning("TreeGen: no grove centers found; placing one at map center.")
		var gs := _fallback_center_spawn()
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
			var t: float = randf() * TAU
			var r_cells: float = sqrt(randf()) * float(g.radius_cells)
			var ox_i: int = int(round(cos(t) * r_cells))
			var oy_i: int = int(round(sin(t) * r_cells))
			var cell := Vector2i(clampi(g.center_cell.x + ox_i, 0, W - 1), clampi(g.center_cell.y + oy_i, 0, H - 1))

			var spawn := _find_nearby_ground(cell, micro_spawn_attempts)
			if spawn == null:
				continue

			_trunk_total_px = clampi(randi_range(trunk_total_px_min, trunk_total_px_max), 4, 4096)
			_trunk_width_px = clampi(randi_range(trunk_width_px_min, trunk_width_px_max), 1, 4096)

			_build_tree_at(spawn, g.bark_region, g.leaf_region)

# ─────────────────────────── Grove planning helpers ───────────────────────────
func _plan_groves(spacing_cells: int, slope_allow: int, grass_required: bool, attempts: int) -> Array[Grove]:
	var groves: Array[Grove] = []
	var want: int = clampi(randi_range(grove_count_min, grove_count_max), 1, 64)
	var margin: int = clampi(spawn_margin_cells, 0, min(W, H) / 2)
	var tries: int = 0
	while groves.size() < want and tries < attempts:
		tries += 1
		var x: int = randi_range(margin, max(margin, W - 1 - margin))
		var y: int = randi_range(margin, max(margin, H - 1 - margin))

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
		g.radius_cells = clampi(randi_range(grove_radius_cells_min, grove_radius_cells_max), 1, 64)
		g.tree_count = clampi(randi_range(trees_per_grove_min, trees_per_grove_max), 1, 256)
		g.bark_region = _choose_bark_region()
		g.leaf_region = _choose_leaf_subtile_region(_choose_one_leaf_tile())
		if g.bark_region.size != Vector2i.ZERO and g.leaf_region.size != Vector2i.ZERO:
			groves.append(g)

	return groves

func _choose_bark_region() -> Rect2i:
	return _atlas_src.get_tile_texture_region(_choose_bark_tile())

func _choose_bark_tile() -> Vector2i:
	var bx: int = randi_range(min(bark_x_range.x, bark_x_range.y), max(bark_x_range.x, bark_x_range.y))
	var by: int = randi_range(min(bark_y_range.x, bark_y_range.y), max(bark_y_range.x, bark_y_range.y))
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
	return pool[randi_range(0, pool.size() - 1)]

func _choose_leaf_subtile_region(tile_xy: Vector2i) -> Rect2i:
	var full: Rect2i = _atlas_src.get_tile_texture_region(tile_xy)
	if full.size == Vector2i.ZERO:
		return full
	var cols: int = max(1, leaf_subtile_cols)
	var rows: int = max(1, leaf_subtile_rows)
	var pick: int = randi_range(0, cols * rows - 1)
	var c_idx: int = pick % cols
	var r_idx: int = int(floor(float(pick) / float(cols)))
	var sub_w: int = max(1, int(floor(float(full.size.x) / float(cols))))
	var sub_h: int = max(1, int(floor(float(full.size.y) / float(rows))))
	return Rect2i(
		Vector2i(full.position.x + c_idx * sub_w, full.position.y + r_idx * sub_h),
		Vector2i(sub_w, sub_h)
	)

# ───────────────────────── Map helpers (read-only) ────────────────────────────
func _get_map() -> Node:
	return get_node_or_null(map_ref)

func _map_surface_z(x: int, y: int) -> int:
	var m := _get_map()
	if m == null or not m.has_method("surface_z_at"):
		return -1
	return int(m.call("surface_z_at", x, y))

func _map_is_grassy(_x: int, _y: int, _z: int) -> bool:
	return true

func _column_bottom_world(x: int, y: int, z: int) -> Vector2:
	var m := _get_map()
	if m != null and m.has_method("_project_iso3d"):
		return Vector2(m.call("_project_iso3d", float(x), float(y), float(z)))
	return global_position

static func _sort_key(x: int, y: int, z: int) -> int:
	return y * 128 + x * 4 + z

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

func _find_nearby_ground(target: Vector2i, tries: int) -> GroundSpawn:
	var margin: int = clampi(spawn_margin_cells, 0, min(W, H) / 2)
	for _i in range(tries):
		var rx: int = randi_range(-2, 2)
		var ry: int = randi_range(-2, 2)
		var cx: int = clampi(target.x + rx, margin, W - 1 - margin)
		var cy: int = clampi(target.y + ry, margin, H - 1 - margin)
		var z: int = _map_surface_z(cx, cy)
		if z < 0:
			continue
		if require_grass_top and not _map_is_grassy(cx, cy, z):
			continue
		if not _is_flat_enough(cx, cy):
			continue
		var pos: Vector2 = _column_bottom_world(cx, cy, z)

		var halfw: int = max(0, footprint_half_width_cells)
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
		gs.cell = Vector2i(cx, cy)
		gs.z = z
		return gs
	return null

func _fallback_center_spawn() -> GroundSpawn:
	var cx: int = int(float(W) / 2.0)
	var cy: int = int(float(H) / 2.0)
	var z: int = _map_surface_z(cx, cy); if z < 0: z = 0
	var gs := GroundSpawn.new()
	gs.position = _column_bottom_world(cx, cy, z)
	gs.cell = Vector2i(cx, cy)
	gs.z = z
	return gs

# ───────────────────────── Build one tree at spawn ────────────────────────────
func _build_tree_at(spawn: GroundSpawn, bark_region: Rect2i, leaf_region: Rect2i) -> void:
	# temp group: build full tree here, then bake+outline to a single sprite
	var temp: Node2D = Node2D.new()
	add_child(temp) # short-lived; baked and freed

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
	var want_count: int = clampi(randi_range(branch_count_min, branch_count_max), 0, 64)

	var branch_targets: Array[int] = []
	var guard: int = 0
	while branch_targets.size() < want_count and guard < 200:
		guard += 1
		var y_try: int = randi_range(min_px, max_px)
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
		branch_lengths.append(clampi(randi_range(branch_length_min_px, branch_length_max_px), 3, 999))

	var next_branch_idx: int = 0
	var next_branch_px: int = (branch_targets[next_branch_idx] if branch_targets.size() > 0 else 1 << 30)
	var branch_side: int = -1

	# ── Trunk build (records anchors) ──
	var lateral: int = 0
	var current_top_y_world: float = bottom_world.y
	var built_px: int = 0

	while built_px < _trunk_total_px:
		var seg_h: int = min(randi_range(2, 3), _trunk_total_px - built_px)

		# wobble
		if randf() < wiggle_prob:
			var r: float = randf() * 2.0 - 1.0
			var biased: float = r + clamp(wiggle_bias, -1.0, 1.0)
			var move: int = (1 if biased > 0.33 else (-1 if biased < -0.33 else 0))
			lateral = clampi(lateral + move, -max_lateral_px, max_lateral_px)

		# sample bark rows
		var cycle_i: int = built_px % tile_h_px
		var base_row: int = tile_h_px - 1 - cycle_i
		var rand_step: int = randi_range(0, 2)
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
				side = (1 if randf() < p_right else -1)

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
	_outline_entire_tree(temp, spawn)

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

	var place_single: bool = (randf() < leaf_single_on_branch_chance)
	var single_t: float = randf() if place_single else 0.0
	var single_done: bool = false

	while placed_px < branch_len_px:
		var seg_h_raw: int = min(randi_range(branch_step_h_px.x, branch_step_h_px.y), branch_len_px - placed_px)
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
		var rand_step: int = randi_range(0, 2)
		var start_row: int = clampi(base_row - rand_step - (seg_h - 1), 0, tile_h_px - seg_h)
		var sample_y: int = bark_region.position.y + start_row
		var region_rect: Rect2 = Rect2(Vector2(local_slice_x, sample_y), Vector2(width_now, seg_h))

		var jitter: int = randi_range(-branch_dev_px, branch_dev_px)
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
	var tip_count: int = randi_range(leaf_tip_count_min, leaf_tip_count_max)
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
	temp.add_child(spr)
	return spr

func _try_connected_leaf(temp: Node2D, center_world: Vector2, spawn: GroundSpawn, leaf_region: Rect2i, radius_px: int, anchors: Array[Rect2]) -> bool:
	var sz: Vector2 = Vector2(leaf_region.size)

	# 1) Random attempts within disc, but require a minimum overlap (not just touch)
	for _i in range(max(1, leaf_connect_attempts)):
		var ox: int = randi_range(-radius_px, radius_px)
		var max_y: int = int(sqrt(max(0.0, float(radius_px * radius_px - ox * ox))))
		var oy: int = randi_range(-max_y, max_y)

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
func _outline_entire_tree(temp: Node2D, spawn: GroundSpawn) -> void:
	# Create a transient factory, bake, parent result under trunks_root, free temp+factory
	var factory: TreeOutlineFactory = TreeOutlineFactory.new()
	add_child(factory)

	var z_final: int = _sort_key(spawn.cell.x, spawn.cell.y, spawn.z + leaves_z_offset + 1)
	var outlined: Sprite2D = await factory.bake_tree(
		temp,               # group containing ALL sprites for this tree
		spawn.position,     # bottom-center anchor in world
		z_final,            # final z-index
		trunks_root         # parent for output
	)

	factory.queue_free()
	# temp is freed inside bake_tree()
