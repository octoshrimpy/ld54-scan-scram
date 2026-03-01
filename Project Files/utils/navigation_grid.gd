extends Resource
class_name NavigationGrid

const MapUtilsRef := preload("res://utils/map_utils.gd")
const CARDINAL_DIRS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
]
const DIAGONAL_DIRS: Array[Vector2i] = [
	Vector2i(1, 1),
	Vector2i(1, -1),
	Vector2i(-1, 1),
	Vector2i(-1, -1),
]

# NavigationGrid — builds an A* grid over the terrain heights so multiple
# agents can query shared paths and world-space coordinates.

@export var max_step_height: int = 1               # Max vertical delta between neighbors
@export var allow_diagonal: bool = false           # Allow diagonal moves
@export var allow_water: bool = false              # If true, water columns are traversable
@export var block_obstacles: bool = true           # Respect map-provided obstacle masks
@export var extra_cost_per_height: float = 0.25    # Additional weight per elevation change

var _map: Node
var _grid: AStarGrid2D = AStarGrid2D.new()
var _region: Rect2i = Rect2i()
var _height_cache: Dictionary = {}
var _map_signal_owner: Node

func configure(map_ref: Node, region: Rect2i) -> void:
	_map = map_ref
	_region = region
	_height_cache.clear()
	_bind_map_signals(_map)
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
	_height_cache.clear()
	rebuild()

func set_map(map_ref: Node) -> void:
	if _map == map_ref and _map_signal_owner == map_ref:
		return
	_map = map_ref
	_height_cache.clear()
	_bind_map_signals(_map)
	rebuild()

func has_point(cell: Vector2i) -> bool:
	return _cell_in_region(cell)

func is_walkable(cell: Vector2i) -> bool:
	if not has_point(cell):
		return false
	return not _is_point_disabled(cell)

func get_region() -> Rect2i:
	return _region

func get_grid() -> AStarGrid2D:
	return _grid

func get_cell_path(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	if _grid == null:
		return []
	if not has_point(start) or not has_point(goal):
		return []
	if _is_point_disabled(start) or _is_point_disabled(goal):
		return []
	var packed_path: PackedVector2Array = PackedVector2Array()
	if _grid.has_method("get_point_path"):
		packed_path = _grid.call("get_point_path", start, goal)
	else:
		var packed_variant: Variant = _grid.call("get_id_path", start, goal)
		if packed_variant is PackedVector2Array:
			packed_path = packed_variant
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
	if _map.has_method("cell_to_world"):
		return _map.call("cell_to_world", cell)
	var z := MapUtilsRef.surface_z(_map, cell.x, cell.y, 0)
	return MapUtilsRef.project_iso3d(_map, float(cell.x), float(cell.y), float(z))

func get_cell_height(cell: Vector2i) -> int:
	return _height_at(cell)

func find_closest_walkable(cell: Vector2i, max_radius: int = 8) -> Vector2i:
	if has_point(cell) and not _is_point_disabled(cell):
		return cell
	var clamped := _clamp_to_region(cell)
	if has_point(clamped) and not _is_point_disabled(clamped):
		return clamped
	var radius_limit: int = max(1, max_radius)
	for radius in range(1, radius_limit + 1):
		var min_x := clamped.x - radius
		var max_x := clamped.x + radius
		var min_y := clamped.y - radius
		var max_y := clamped.y + radius
		for y in range(min_y, max_y + 1):
			for x in range(min_x, max_x + 1):
				var candidate := Vector2i(x, y)
				if not _cell_in_region(candidate):
					continue
				if _is_point_disabled(candidate):
					continue
				return candidate
	return clamped

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
			if not disabled and block_obstacles and _is_obstacle_cell(cell):
				disabled = true
			_set_point_disabled(cell, disabled)
			if not disabled:
				_set_point_weight(cell, _weight_for_cell(cell))

func _apply_height_rules() -> void:
	var start_x: int = _region.position.x
	var end_x: int = _region.position.x + _region.size.x
	var start_y: int = _region.position.y
	var end_y: int = _region.position.y + _region.size.y
	var neighbor_dirs: Array[Vector2i] = CARDINAL_DIRS.duplicate()
	if allow_diagonal:
		neighbor_dirs.append_array(DIAGONAL_DIRS)

	for y in range(start_y, end_y):
		for x in range(start_x, end_x):
			var cell := Vector2i(x, y)
			if _is_point_disabled(cell):
				continue
			var base_height := _height_at(cell)
			var weight_factor := 1.0
			for dir in neighbor_dirs:
				var neighbor := cell + dir
				if not has_point(neighbor):
					continue
				if _is_point_disabled(neighbor):
					continue
				var neighbor_height := _height_at(neighbor)
				if neighbor_height < 0:
					continue
				if abs(neighbor_height - base_height) > max_step_height:
					_set_connection_disabled(cell, neighbor, true)
					_set_connection_disabled(neighbor, cell, true)
				else:
					var slope := float(abs(neighbor_height - base_height))
					if slope > 0.0:
						weight_factor = max(weight_factor, 1.0 + slope * max(0.0, extra_cost_per_height))
			var base_weight := _weight_for_cell(cell)
			_set_point_weight(cell, base_weight * weight_factor)

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

func _cell_in_region(cell: Vector2i) -> bool:
	if _region.size == Vector2i.ZERO:
		return false
	if cell.x < _region.position.x or cell.y < _region.position.y:
		return false
	if cell.x >= _region.position.x + _region.size.x:
		return false
	if cell.y >= _region.position.y + _region.size.y:
		return false
	return true

func _clamp_to_region(cell: Vector2i) -> Vector2i:
	if _region.size == Vector2i.ZERO:
		return cell
	var min_x := _region.position.x
	var min_y := _region.position.y
	var max_x := _region.position.x + _region.size.x - 1
	var max_y := _region.position.y + _region.size.y - 1
	return Vector2i(
		clampi(cell.x, min_x, max_x),
		clampi(cell.y, min_y, max_y)
	)

func _set_point_disabled(cell: Vector2i, disabled: bool) -> void:
	if _grid == null:
		return
	if not _cell_in_region(cell):
		return
	if _grid.has_method("set_point_disabled"):
		_grid.call("set_point_disabled", cell, disabled)

func _is_point_disabled(cell: Vector2i) -> bool:
	if _grid == null:
		return false
	if not _cell_in_region(cell):
		return true
	if _grid.has_method("is_point_disabled"):
		return bool(_grid.call("is_point_disabled", cell))
	return false

func _set_point_weight(cell: Vector2i, weight: float) -> void:
	if _grid == null:
		return
	if not _cell_in_region(cell):
		return
	if _grid.has_method("set_point_weight_scale"):
		_grid.call("set_point_weight_scale", cell, weight)

func _set_connection_disabled(a: Vector2i, b: Vector2i, disabled: bool) -> void:
	if _grid == null:
		return
	if not _cell_in_region(a) or not _cell_in_region(b):
		return
	if _grid.has_method("set_point_connection_disabled"):
		_grid.call("set_point_connection_disabled", a, b, disabled)

func _is_obstacle_cell(cell: Vector2i) -> bool:
	if _map == null:
		return false
	if _map.has_method("is_obstacle_cell"):
		return bool(_map.call("is_obstacle_cell", cell.x, cell.y))
	return false

func _bind_map_signals(map_ref: Node) -> void:
	_unbind_map_signals()
	if map_ref == null or not is_instance_valid(map_ref):
		return
	if map_ref.has_signal("map_rebuilt"):
		var cb := Callable(self, "_on_map_rebuilt")
		if not map_ref.map_rebuilt.is_connected(cb):
			map_ref.map_rebuilt.connect(cb, CONNECT_REFERENCE_COUNTED)
	_map_signal_owner = map_ref

func _unbind_map_signals() -> void:
	if _map_signal_owner == null or not is_instance_valid(_map_signal_owner):
		_map_signal_owner = null
		return
	var cb := Callable(self, "_on_map_rebuilt")
	if _map_signal_owner.has_signal("map_rebuilt") and _map_signal_owner.map_rebuilt.is_connected(cb):
		_map_signal_owner.map_rebuilt.disconnect(cb)
	_map_signal_owner = null

func _on_map_rebuilt() -> void:
	rebuild()
