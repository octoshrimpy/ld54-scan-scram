extends Node2D
class_name PathfindingAgent

const NavigationGridRef := preload("res://utils/navigation_grid.gd")

# PathfindingAgent — shareable base class that gives inheriting entities
# grid-based A* navigation over the PlanetMap.
# Usage:
#   • Set `map_path` to the PlanetMap node (or let it default to parent).
#   • Assign a shared `NavigationGrid` resource, or let the agent build one.
#   • Call `navigate_to_cell(Vector2i)` to start moving toward a grid cell.
#   • Listen for `path_completed`, `path_blocked`, etc. for state changes.

signal path_started(target: Vector2i)
signal path_step(reached: Vector2i)
signal path_completed(target: Vector2i)
signal path_failed(target: Vector2i)
signal path_blocked(blocked_at: Vector2i)

@export var map_path: NodePath
@export var navigation_grid: NavigationGridRef
@export var auto_build_navigation: bool = true
@export var move_speed: float = 64.0
@export var arrival_radius: float = 6.0
@export var current_cell: Vector2i = Vector2i.ZERO
@export var max_step_height: int = 1
@export var allow_diagonal: bool = false
@export var allow_water: bool = false
@export var world_offset: Vector2 = Vector2.ZERO

var _map: Node
var _nav: NavigationGridRef
var _owns_navigation: bool = false
var _cell_path: Array[Vector2i] = []
var _world_path: Array[Vector2] = []
var _path_index: int = 0
var _target_cell: Vector2i = Vector2i(-1, -1)
var _is_moving: bool = false

func _ready() -> void:
	_map = _resolve_map()
	_setup_navigation()

func _physics_process(delta: float) -> void:
	if not _is_moving or _nav == null or _world_path.is_empty():
		return
	if _path_index >= _world_path.size():
		_finish_path()
		return

	var target_point: Vector2 = _world_path[_path_index]
	var to_target: Vector2 = target_point - global_position

	if to_target.length() <= arrival_radius:
		global_position = target_point
		if _path_index < _cell_path.size():
			current_cell = _cell_path[_path_index]
			emit_signal("path_step", current_cell)
		_path_index += 1
		if _path_index >= _world_path.size():
			_finish_path()
		return

	if _path_index < _cell_path.size() and not _nav.is_walkable(_cell_path[_path_index]):
		var blocked_cell := _cell_path[_path_index]
		stop_path(true)
		emit_signal("path_blocked", blocked_cell)
		return

	var step_distance: float = move_speed * delta
	if step_distance >= to_target.length():
		global_position = target_point
	else:
		var direction: Vector2 = to_target.normalized()
		global_position += direction * step_distance

func navigate_to_cell(target_cell: Vector2i, force_nav_rebuild: bool = false) -> bool:
	if target_cell == current_cell:
		_target_cell = target_cell
		emit_signal("path_completed", target_cell)
		return true
	if _nav == null:
		push_warning("PathfindingAgent: navigation grid is not set.")
		return false
	if force_nav_rebuild and _owns_navigation:
		_nav.rebuild()

	var path: Array[Vector2i] = _nav.get_cell_path(current_cell, target_cell)
	if path.is_empty():
		emit_signal("path_failed", target_cell)
		return false

	_prepare_path(path)
	_target_cell = target_cell
	_is_moving = _world_path.size() > 1
	emit_signal("path_started", target_cell)
	return true

func stop_path(preserve_target: bool = false) -> void:
	_is_moving = false
	_cell_path.clear()
	_world_path.clear()
	_path_index = 0
	if not preserve_target:
		_target_cell = Vector2i(-1, -1)

func set_navigation_grid(nav: NavigationGridRef, owns_navigation: bool = false) -> void:
	_nav = nav
	_owns_navigation = owns_navigation
	if _nav == null:
		return
	if owns_navigation:
		_sync_agent_preferences()

func rebuild_navigation(region: Rect2i = Rect2i()) -> void:
	if _nav == null:
		return
	if region.size != Vector2i.ZERO and _owns_navigation:
		_nav.set_region(region)
	else:
		_nav.rebuild()

func set_current_cell(cell: Vector2i, snap_to_world: bool = false) -> void:
	current_cell = cell
	if snap_to_world and _nav != null:
		global_position = _nav.cell_to_world(cell) + world_offset

func cell_to_world(cell: Vector2i) -> Vector2:
	if _nav == null:
		return Vector2.ZERO
	return _nav.cell_to_world(cell) + world_offset

func world_to_cell(world: Vector2) -> Vector2i:
	if _nav == null or _map == null:
		return current_cell
	var offset_world := world - world_offset
	var rect := _nav.get_region()
	var best_cell := current_cell
	var best_dist := INF
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			var cell := Vector2i(x, y)
			if not _nav.is_walkable(cell):
				continue
			var pos := _nav.cell_to_world(cell)
			var d := pos.distance_squared_to(offset_world)
			if d < best_dist:
				best_dist = d
				best_cell = cell
	return best_cell

func _resolve_map() -> Node:
	if map_path == NodePath():
		return get_parent()
	var map_node := get_node_or_null(map_path)
	if map_node == null:
		push_warning("PathfindingAgent: map node at %s not found." % str(map_path))
	return map_node

func _setup_navigation() -> void:
	if navigation_grid != null:
		_nav = navigation_grid
		_owns_navigation = false
	elif auto_build_navigation:
		var dims := _resolve_map_dimensions()
		if dims == Vector2i.ZERO or _map == null:
			push_warning("PathfindingAgent: cannot build navigation grid without valid map and dimensions.")
			return
		_nav = NavigationGridRef.new()
		_owns_navigation = true
		_sync_agent_preferences()
		var region := Rect2i(Vector2i.ZERO, dims)
		_nav.configure(_map, region)
	else:
		_nav = null
		_owns_navigation = false

func _sync_agent_preferences() -> void:
	if _nav == null:
		return
	_nav.max_step_height = max_step_height
	_nav.allow_diagonal = allow_diagonal
	_nav.allow_water = allow_water

func _resolve_map_dimensions() -> Vector2i:
	if _map == null:
		return Vector2i.ZERO
	if _map.has_method("get_dimensions"):
		var dims = _map.call("get_dimensions")
		if dims is Vector2i:
			return dims
		if dims is Vector2:
			return Vector2i(int(dims.x), int(dims.y))
	return Vector2i.ZERO

func _prepare_path(path: Array[Vector2i]) -> void:
	_cell_path = path
	_world_path.clear()
	for cell in path:
		_world_path.append(_nav.cell_to_world(cell) + world_offset)
	_path_index = 1 if path.size() > 1 else 0

func _finish_path() -> void:
	if not _cell_path.is_empty():
		current_cell = _cell_path.back()
	emit_signal("path_completed", _target_cell)
	stop_path()
