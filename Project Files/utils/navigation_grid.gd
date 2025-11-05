extends Resource
class_name NavigationGrid

const MapUtilsRef := preload("res://utils/map_utils.gd")

# NavigationGrid — builds an A* grid over the terrain heights so multiple
# agents can query shared paths and world-space coordinates.

@export var max_step_height: int = 1               # Max vertical delta between neighbors
@export var allow_diagonal: bool = false           # Allow diagonal moves
@export var allow_water: bool = false              # If true, water columns are traversable
@export var extra_cost_per_height: float = 0.25    # Additional weight per elevation change

var _map: Node
var _grid: AStarGrid2D = AStarGrid2D.new()
var _region: Rect2i = Rect2i()
var _height_cache: Dictionary = {}

func configure(map_ref: Node, region: Rect2i) -> void:
	_map = map_ref
	_region = region
	_height_cache.clear()
	_setup_grid()
	_bake_walkable_mask()
	_apply_height_rules()

func rebuild() -> void:
	if _map == null or _region.size == Vector2i.ZERO:
		return
	_height_cache.clear()
	_setup_grid()
	_bake_walkable_mask()
	_apply_height_rules()

func set_region(region: Rect2i) -> void:
	_region = region
	rebuild()

func set_map(map_ref: Node) -> void:
	_map = map_ref
	rebuild()

func has_point(cell: Vector2i) -> bool:
	return _grid.region.has_point(cell)

func is_walkable(cell: Vector2i) -> bool:
	if not has_point(cell):
		return false
	return not _grid.is_point_disabled(cell)

func get_region() -> Rect2i:
	return _region

func get_grid() -> AStarGrid2D:
	return _grid

func get_cell_path(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	if _grid == null:
		return []
	if not has_point(start) or not has_point(goal):
		return []
	if _grid.is_point_disabled(start) or _grid.is_point_disabled(goal):
		return []
	var packed_path: PackedVector2Array = _grid.get_id_path(start, goal)
	var result: Array[Vector2i] = []
	for point in packed_path:
		result.append(Vector2i(roundi(point.x), roundi(point.y)))
	return result

func get_world_path(start: Vector2i, goal: Vector2i) -> Array[Vector2]:
	var cells := get_cell_path(start, goal)
	var path: Array[Vector2] = []
	for cell in cells:
		path.append(cell_to_world(cell))
	return path

func cell_to_world(cell: Vector2i) -> Vector2:
	if _map == null:
		return Vector2.ZERO
	var z := MapUtilsRef.surface_z(_map, cell.x, cell.y, 0)
	return MapUtilsRef.project_iso3d(_map, float(cell.x), float(cell.y), float(z))

func get_cell_height(cell: Vector2i) -> int:
	return _height_at(cell)

func _setup_grid() -> void:
	_grid.region = _region
	_grid.cell_size = Vector2.ONE
	_grid.diagonal_mode = (
		AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES if allow_diagonal
		else AStarGrid2D.DIAGONAL_MODE_NEVER
	)
	_grid.update()

func _bake_walkable_mask() -> void:
	var start_x: int = _region.position.x
	var end_x: int = _region.position.x + _region.size.x
	var start_y: int = _region.position.y
	var end_y: int = _region.position.y + _region.size.y
	for y in range(start_y, end_y):
		for x in range(start_x, end_x):
			var cell := Vector2i(x, y)
			var height := _height_at(cell)
			var disabled := height < 0
			if not disabled and not allow_water and MapUtilsRef.column_has_water(_map, x, y):
				disabled = true
			_grid.set_point_disabled(cell, disabled)
			if not disabled:
				_grid.set_point_weight_scale(cell, _weight_for_cell(cell))

func _apply_height_rules() -> void:
	var start_x: int = _region.position.x
	var end_x: int = _region.position.x + _region.size.x
	var start_y: int = _region.position.y
	var end_y: int = _region.position.y + _region.size.y
	var neighbor_dirs: Array[Vector2i] = [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1),
	]
	if allow_diagonal:
		neighbor_dirs.append_array([
			Vector2i(1, 1),
			Vector2i(1, -1),
			Vector2i(-1, 1),
			Vector2i(-1, -1),
		])

	for y in range(start_y, end_y):
		for x in range(start_x, end_x):
			var cell := Vector2i(x, y)
			if _grid.is_point_disabled(cell):
				continue
			var base_height := _height_at(cell)
			var weight_factor := 1.0
			for dir in neighbor_dirs:
				var neighbor := cell + dir
				if not has_point(neighbor):
					continue
				if _grid.is_point_disabled(neighbor):
					continue
				var neighbor_height := _height_at(neighbor)
				if neighbor_height < 0:
					continue
				if abs(neighbor_height - base_height) > max_step_height:
					_grid.set_point_connection_disabled(cell, neighbor, true)
					_grid.set_point_connection_disabled(neighbor, cell, true)
				else:
					var slope := float(abs(neighbor_height - base_height))
					if slope > 0.0:
						weight_factor = max(weight_factor, 1.0 + slope * max(0.0, extra_cost_per_height))
			var base_weight := _weight_for_cell(cell)
			_grid.set_point_weight_scale(cell, base_weight * weight_factor)

func _height_at(cell: Vector2i) -> int:
	if _height_cache.has(cell):
		return _height_cache[cell]
	if _map == null:
		return -1
	var h := MapUtilsRef.surface_z(_map, cell.x, cell.y, -1)
	_height_cache[cell] = h
	return h

func _weight_for_cell(cell: Vector2i) -> float:
	if _map == null:
		return 1.0
	var height := _height_at(cell)
	return 1.0 + 0.01 * float(max(0, height))
