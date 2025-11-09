# redshirt_spawner.gd — Handles crew spawn clustering and sprite selection.
class_name RedshirtSpawner
extends RefCounted

var tile_min: Vector2i = Vector2i(33, 5)
var tile_max: Vector2i = Vector2i(34, 9)
var crew_min: int = 3
var crew_max: int = 7
var cluster_radius_base: int = 3
var cluster_radius_expand_start: int = 4
var cluster_radius_step: float = 0.5
var max_attempts: int = 40
var flip_chance: float = 0.5
var _active_radius: int = 3
const LAND_SAMPLE_MULTIPLIER: int = 8
const LAND_SAMPLE_MIN: int = 36

var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_rng.randomize()

func set_seed(seed: int) -> void:
	_rng.seed = seed

func spawn_redshirts(
	_place_sprite: Callable,
	is_water: Callable,
	surfaces: Array,
	width: int,
	height: int,
	z_max: int
) -> Array[Dictionary]:
	var min_count: int = max(1, min(crew_min, crew_max))
	var max_count: int = max(min_count, max(crew_min, crew_max))
	if max_count <= 0:
		return []
	if not is_water.is_valid():
		return []

	var target_count: int = _rng.randi_range(min_count, max_count)
	var flip_prob: float = clampf(flip_chance, 0.0, 1.0)

	var land_cells: Array[Vector3i] = _collect_land_cells(is_water, surfaces, width, height, target_count)
	if land_cells.is_empty():
		return []

	_active_radius = _effective_radius(target_count)

	var cluster: Array[Vector2i] = _select_cluster(land_cells, target_count)
	if cluster.size() < target_count and land_cells.size() < width * height:
		land_cells = _collect_land_cells(is_water, surfaces, width, height, target_count, true)
		if land_cells.is_empty():
			return []
		cluster = _select_cluster(land_cells, target_count)
	if cluster.is_empty():
		return []

	if cluster.size() > target_count:
		_shuffle_array(cluster)
		cluster.resize(target_count)

	var placements: Array[Dictionary] = []
	for pos_variant in cluster:
		var pos: Vector2i = pos_variant
		if pos.y < 0 or pos.y >= surfaces.size():
			continue
		var row: Array = surfaces[pos.y]
		if pos.x < 0 or pos.x >= row.size():
			continue
		var z_surf: int = int(row[pos.x])
		var z_top: int = min(z_surf + 1, z_max)
		placements.append({
			"pos": pos,
			"z_top": z_top,
			"atlas": _random_tile(),
			"flip_h": _rng.randf() < flip_prob
		})

	return placements

func _collect_land_cells(
	is_water: Callable,
	surfaces: Array,
	width: int,
	height: int,
	target_count: int,
	force_full_scan: bool = false
) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var goal: int = width * height
	if not force_full_scan:
		var sample_goal: int = max(target_count * LAND_SAMPLE_MULTIPLIER, LAND_SAMPLE_MIN)
		goal = min(goal, sample_goal)
	if goal <= 0:
		return cells
	var start_y: int = (0 if height <= 0 else _rng.randi_range(0, max(0, height - 1)))
	var start_x: int = (0 if width <= 0 else _rng.randi_range(0, max(0, width - 1)))
	for y_offset in range(height):
		var y := ((start_y + y_offset) % height) if height > 0 else 0
		if y < 0 or y >= surfaces.size():
			continue
		var row: Array = surfaces[y] as Array
		for x_offset in range(width):
			var x := ((start_x + x_offset) % width) if width > 0 else 0
			if bool(is_water.call(x, y)):
				continue
			if x < 0 or x >= row.size():
				continue
			var z_surf: int = int(row[x])
			cells.append(Vector3i(x, y, z_surf))
			if not force_full_scan and cells.size() >= goal:
				return cells
	return cells

func _select_cluster(land_cells: Array[Vector3i], target_count: int) -> Array[Vector2i]:
	if land_cells.is_empty():
		return []
	var elevations: Array[int] = []
	var cells_by_height: Dictionary = {}
	for cell in land_cells:
		var z: int = cell.z
		if not cells_by_height.has(z):
			cells_by_height[z] = []
			elevations.append(z)
		var cell_list: Array = cells_by_height[z]
		cell_list.append(Vector2i(cell.x, cell.y))
		cells_by_height[z] = cell_list
	elevations.sort()
	elevations.reverse()

	var best_cluster: Array[Vector2i] = []
	for i in range(elevations.size()):
		var z_cutoff: int = elevations[i]
		var candidate_cells: Array[Vector2i] = []
		for z in elevations:
			if z < z_cutoff:
				continue
			var list: Array = cells_by_height[z]
			for cell_variant in list:
				var pos: Vector2i = cell_variant
				candidate_cells.append(pos)
		if candidate_cells.is_empty():
			continue
		var cluster: Array[Vector2i] = _find_cluster(candidate_cells, target_count)
		if cluster.size() >= target_count:
			return cluster
		if cluster.size() > best_cluster.size():
			best_cluster = cluster.duplicate()
	return best_cluster

func _find_cluster(land_cells: Array[Vector2i], target_count: int) -> Array[Vector2i]:
	if land_cells.is_empty():
		return []
	var best_cluster: Array[Vector2i] = []
	for _attempt in range(max(1, max_attempts)):
		var anchor: Vector2i = land_cells[_rng.randi_range(0, land_cells.size() - 1)]
		var candidate_cluster := _build_cluster(anchor, land_cells, target_count)
		if candidate_cluster.size() > best_cluster.size():
			best_cluster = candidate_cluster.duplicate()
		if candidate_cluster.size() >= target_count:
			return candidate_cluster
	return best_cluster

func _build_cluster(anchor: Vector2i, land_cells: Array[Vector2i], target_count: int) -> Array[Vector2i]:
	var cluster: Array[Vector2i] = [anchor]
	var shuffled: Array = land_cells.duplicate()
	_shuffle_array(shuffled)
	for cell_variant in shuffled:
		var cell: Vector2i = cell_variant
		if cell == anchor:
			continue
		if cluster.size() >= target_count:
			break
		if not _within_radius(anchor, cell):
			continue
		var fits_all := true
		for existing_variant in cluster:
			var existing: Vector2i = existing_variant
			if not _within_radius(existing, cell):
				fits_all = false
				break
		if fits_all:
			cluster.append(cell)
			if cluster.size() >= target_count:
				break
	return cluster

func _within_radius(a: Vector2i, b: Vector2i) -> bool:
	return max(abs(a.x - b.x), abs(a.y - b.y)) <= _active_radius

func _effective_radius(count: int) -> int:
	var base_radius: float = float(max(1, cluster_radius_base))
	if count > cluster_radius_expand_start:
		var extra: int = count - cluster_radius_expand_start
		base_radius += float(extra) * max(0.0, cluster_radius_step)
	return int(ceil(base_radius))

func _random_tile() -> Vector2i:
	var min_x: int = min(tile_min.x, tile_max.x)
	var max_x: int = max(tile_min.x, tile_max.x)
	var min_y: int = min(tile_min.y, tile_max.y)
	var max_y: int = max(tile_min.y, tile_max.y)
	return Vector2i(_rng.randi_range(min_x, max_x), _rng.randi_range(min_y, max_y))

func _shuffle_array(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
