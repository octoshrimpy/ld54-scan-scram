# redshirt_agent.gd — Animated Sprite2D that wanders across the terrain surface.
class_name RedshirtAgent
extends Sprite2D

const MapUtilsRef := preload("res://utils/map_utils.gd")
const CARDINAL_DIRS := [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
]
const WALK_BOB_HALF_TIME_MAX: float = 0.18
const WALK_BOB_LATERAL_PX: float = 1.6
const WALK_BOB_VERTICAL_PX: float = 2.4
const HOP_ARC_BASE_PX: float = 3.0
const HOP_ARC_PER_LEVEL_PX: float = 2.0
const TURN_PAGE_HALF_TIME: float = 0.08
const TURN_FLIP_MIN_SCALE: float = 0.25
const HOPS_PER_TILE: int = 2
const HOP_CHAIN_PAUSE: float = 0.16

const DEBUG_SHOW_COLLISION: bool = false
const DEBUG_COLLISION_COLOR := Color(1.0, 0.2, 0.2, 0.6)
const DEBUG_PIVOT_COLOR := Color(0.2, 0.8, 1.0, 0.8)
const DEBUG_LINE_WIDTH: float = 1.0
const Z_INDEX_LIFT: int = 2

var _map_ref: Node
var _cell: Vector2i = Vector2i.ZERO
var _wander_center: Vector2i = Vector2i.ZERO
var _wander_radius: int = 2
var _move_interval: Vector2 = Vector2(1.0, 2.0)
var _seconds_per_tile: float = 0.25
var _anchor: Vector2 = Vector2.ZERO
var _sort_bias: int = 0
var _map_dims: Vector2i = Vector2i.ZERO
var _rng := RandomNumberGenerator.new()
var _move_timer: SceneTreeTimer
var _active_tween: Tween
var _anim_tween: Tween
var _flip_tween: Tween
var _sway_sign: int = 1
var _base_scale: Vector2 = Vector2.ONE
var _facing_dir: int = 1
var _hop_segments: Array = []
var _current_hop: int = -1
var _hop_pause_timer: SceneTreeTimer
var _queued_step_dir: Vector2i = Vector2i.ZERO
var _sort_cell: Vector2i = Vector2i.ZERO
var _pending_sort_cell: Vector2i = Vector2i.ZERO
var _sort_hold_active: bool = false
var _sort_release_hop: int = -1
var _debug_region_size: Vector2 = Vector2.ZERO
var _debug_pivot: Vector2 = Vector2.ZERO
var _base_position: Vector2 = Vector2.ZERO
var _visual_offset: Vector2 = Vector2.ZERO
var _texture_center: Vector2 = Vector2.ZERO
var _map_signal_owner: Node
var _wander_enabled: bool = true
var _map_refresh_pending: bool = false

func configure(
	map_ref: Node,
	texture_ref: Texture2D,
	region: Rect2i,
	start_cell: Vector2i,
	anchor: Vector2,
	sort_bias: int,
	wander_center: Vector2i,
	wander_radius: int,
	move_interval: Vector2,
	seconds_per_tile: float,
	flip_horizontal: bool
) -> void:
	_map_ref = map_ref
	_bind_map_signals(_map_ref)
	_cell = start_cell
	_wander_center = wander_center
	_wander_radius = max(1, wander_radius)
	var min_wait: float = min(move_interval.x, move_interval.y)
	var max_wait: float = max(move_interval.x, move_interval.y)
	_move_interval = Vector2(min_wait, max_wait)
	_seconds_per_tile = max(0.1, seconds_per_tile)
	_anchor = anchor
	_sort_bias = sort_bias
	_map_dims = _resolve_map_dimensions(_map_ref)
	_base_scale = scale
	_facing_dir = (-1 if flip_horizontal else 1)
	_sort_cell = _cell
	_pending_sort_cell = _cell
	_sort_hold_active = false
	_sort_release_hop = -1
	texture = texture_ref
	region_enabled = true
	region_rect = Rect2(region.position, region.size)
	_debug_region_size = region.size
	_texture_center = _debug_region_size * 0.5
	flip_h = false
	scale = Vector2(_base_scale.x * float(_facing_dir), _base_scale.y)
	set("pivot_offset", Vector2.ZERO)
	_debug_pivot = Vector2.ZERO
	centered = true
	z_as_relative = false
	_rng.randomize()
	_wander_enabled = true
	_map_refresh_pending = false
	_snap_to_cell(true)
	_schedule_next_move()
	_refresh_debug_draw()

func _exit_tree() -> void:
	_stop_active_motion()
	_unbind_map_signals()
	_clear_hop_timer()

func _schedule_next_move() -> void:
	if not _wander_enabled:
		return
	if not is_instance_valid(_map_ref):
		return
	if _move_timer and is_instance_valid(_move_timer):
		if _move_timer.timeout.is_connected(_on_move_timer_timeout):
			_move_timer.timeout.disconnect(_on_move_timer_timeout)
	var wait_t := clampf(_rng.randf_range(_move_interval.x, _move_interval.y), 0.05, 10.0)
	_move_timer = get_tree().create_timer(wait_t)
	_move_timer.timeout.connect(_on_move_timer_timeout)

func _on_move_timer_timeout() -> void:
	if not _wander_enabled:
		return
	_move_timer = null
	var next_cell := _pick_next_step()
	if next_cell == _cell:
		_schedule_next_move()
		return
	_move_to(next_cell)

func _pick_next_step() -> Vector2i:
	var options: Array[Vector2i] = []
	for dir in CARDINAL_DIRS:
		var candidate: Vector2i = _cell + dir
		if not _within_wander_radius(candidate):
			continue
		if not _within_bounds(candidate):
			continue
		if not _can_step_to(candidate):
			continue
		options.append(candidate)
	if options.is_empty():
		return _cell
	return options[_rng.randi_range(0, options.size() - 1)]

func _within_bounds(cell: Vector2i) -> bool:
	return (
		cell.x >= 0 and cell.x < _map_dims.x and
		cell.y >= 0 and cell.y < _map_dims.y
	)

func _within_wander_radius(cell: Vector2i) -> bool:
	var dx: int = abs(cell.x - _wander_center.x)
	var dy: int = abs(cell.y - _wander_center.y)
	return max(dx, dy) <= _wander_radius

func _can_step_to(target: Vector2i) -> bool:
	if MapUtilsRef.column_has_water(_map_ref, target.x, target.y):
		return false
	var target_z := MapUtilsRef.surface_z(_map_ref, target.x, target.y, -1)
	if target_z < 0:
		return false
	var current_z := MapUtilsRef.surface_z(_map_ref, _cell.x, _cell.y, -1)
	if current_z < 0:
		return false
	if abs(target_z - current_z) > 1:
		return false
	var target_top := _surface_top_z(target)
	var current_top := _surface_top_z(_cell)
	return abs(target_top - current_top) <= 1

func _move_to(target_cell: Vector2i) -> void:
	var from_cell: Vector2i = _cell
	if target_cell == from_cell:
		_schedule_next_move()
		return
	var segments := _build_hop_segments(from_cell, target_cell)
	_cell = target_cell
	if _active_tween:
		_active_tween.kill()
		_active_tween = null
	if _anim_tween:
		_anim_tween.kill()
		_anim_tween = null
	_set_visual_offset(Vector2.ZERO)
	var step_dir: Vector2i = target_cell - from_cell
	var screen_delta: Vector2 = _cell_sprite_position(target_cell) - _cell_sprite_position(from_cell)
	var facing_changed := _handle_facing(screen_delta)
	_setup_sort_hold(from_cell, target_cell, segments)
	if segments.is_empty():
		_set_base_position(_cell_sprite_position(_cell))
		_set_visual_offset(Vector2.ZERO)
		_sort_cell = target_cell
		_sort_hold_active = false
		_sort_release_hop = -1
		_update_z_index()
		_refresh_debug_draw()
		_schedule_next_move()
		return
	var flip_total: float = TURN_PAGE_HALF_TIME * 2.0
	var initial_delay: float = (max(HOP_CHAIN_PAUSE, flip_total) if facing_changed else HOP_CHAIN_PAUSE)
	_start_hop_sequence(step_dir, segments, initial_delay)

func _start_hop_sequence(step_dir: Vector2i, segments: Array, initial_delay: float) -> void:
	_hop_segments = segments
	_current_hop = -1
	_queue_next_hop(step_dir, initial_delay)

func _setup_sort_hold(from_cell: Vector2i, to_cell: Vector2i, segments: Array) -> void:
	var moving_back := _should_delay_sort(from_cell, to_cell)
	_pending_sort_cell = to_cell
	if not moving_back:
		_sort_hold_active = false
		_sort_release_hop = -1
		_sort_cell = to_cell
		_update_z_index()
		return
	_sort_hold_active = true
	var hop_count: int = max(1, segments.size())
	var half_index: int = int(floor(float(hop_count) * 0.5))
	_sort_release_hop = max(0, half_index - 1)
	_sort_cell = from_cell
	_update_z_index()

func _maybe_release_sort_hold() -> void:
	if not _sort_hold_active:
		return
	if _current_hop >= _sort_release_hop:
		_sort_cell = _pending_sort_cell
		_sort_hold_active = false
		_sort_release_hop = -1
		_update_z_index()

func _queue_next_hop(step_dir: Vector2i, delay: float) -> void:
	_clear_hop_timer()
	_queued_step_dir = step_dir
	if delay <= 0.0:
		_perform_next_hop(_queued_step_dir)
		return
	_hop_pause_timer = get_tree().create_timer(delay)
	_hop_pause_timer.timeout.connect(_on_hop_pause_timeout)

func _on_hop_pause_timeout() -> void:
	_hop_pause_timer = null
	_perform_next_hop(_queued_step_dir)

func _perform_next_hop(step_dir: Vector2i) -> void:
	_current_hop += 1
	if _current_hop >= _hop_segments.size():
		_hop_segments.clear()
		_current_hop = -1
		_clear_hop_timer()
		_schedule_next_move()
		return
	var segment: Dictionary = _hop_segments[_current_hop]
	var start_pos: Vector2 = segment.get("start", position)
	var end_pos: Vector2 = segment.get("end", position)
	var hop_duration: float = max(0.05, float(segment.get("duration", _seconds_per_tile * 0.5)))
	var arc_height: float = max(0.0, float(segment.get("arc", HOP_ARC_BASE_PX)))
	if _active_tween:
		_active_tween.kill()
		_active_tween = null
	if _anim_tween:
		_anim_tween.kill()
		_anim_tween = null
	_set_visual_offset(Vector2.ZERO)
	_set_base_position(start_pos)
	_refresh_debug_draw()
	_active_tween = create_tween()
	var hop_offset: Vector2 = Vector2(0.0, -arc_height)
	var midpoint: Vector2 = start_pos.lerp(end_pos, 0.5) + hop_offset
	var half: float = max(0.01, hop_duration * 0.5)
	_active_tween.tween_method(_set_base_position, start_pos, midpoint, half).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	_active_tween.tween_method(_set_base_position, midpoint, end_pos, half).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_SINE)
	_play_walk_fx(step_dir, hop_duration)
	_active_tween.finished.connect(func ():
		_active_tween = null
		_maybe_release_sort_hold()
		_queue_next_hop(step_dir, HOP_CHAIN_PAUSE)
	)

func _build_hop_segments(from_cell: Vector2i, to_cell: Vector2i) -> Array[Dictionary]:
	var segments: Array[Dictionary] = []
	var hop_count: int = max(1, int(HOPS_PER_TILE))
	var from_top: float = float(_surface_top_z(from_cell))
	var to_top: float = float(_surface_top_z(to_cell))
	for i in range(hop_count):
		var start_frac: float = float(i) / float(hop_count)
		var end_frac: float = float(i + 1) / float(hop_count)
		var start_pos: Vector2 = _path_sprite_position(from_cell, to_cell, start_frac)
		var end_pos: Vector2 = _path_sprite_position(from_cell, to_cell, end_frac)
		var start_height: float = lerpf(from_top, to_top, start_frac)
		var end_height: float = lerpf(from_top, to_top, end_frac)
		var local_delta: float = end_height - start_height
		var duration: float = max(0.05, _seconds_per_tile * (end_frac - start_frac))
		var arc_height: float = HOP_ARC_BASE_PX + HOP_ARC_PER_LEVEL_PX * abs(local_delta)
		segments.append({
			"start": start_pos,
			"end": end_pos,
			"duration": duration,
			"arc": arc_height
		})
	return segments

func _path_sprite_position(from_cell: Vector2i, to_cell: Vector2i, fraction: float) -> Vector2:
	var t := clampf(fraction, 0.0, 1.0)
	if not is_instance_valid(_map_ref):
		var fallback_cell: Vector2i = (from_cell if t < 0.5 else to_cell)
		return _cell_sprite_position(fallback_cell)
	var start := Vector2(float(from_cell.x), float(from_cell.y))
	var delta := Vector2(float(to_cell.x - from_cell.x), float(to_cell.y - from_cell.y))
	var pos_xy := start + delta * t
	var z_from := float(_surface_top_z(from_cell))
	var z_to := float(_surface_top_z(to_cell))
	var z := lerpf(z_from, z_to, t)
	var iso := MapUtilsRef.project_iso3d(_map_ref, pos_xy.x, pos_xy.y, z)
	return iso - _anchor + _texture_center

func _play_walk_fx(step_dir: Vector2i, hop_duration: float) -> void:
	if hop_duration <= 0.0:
		return
	var bob_half: float = clampf(hop_duration * 0.5, 0.05, WALK_BOB_HALF_TIME_MAX)
	var lateral_sign: int = (step_dir.x if step_dir.x != 0 else _sway_sign)
	var lateral_px: float = float(lateral_sign) * WALK_BOB_LATERAL_PX
	var target_a := Vector2(lateral_px, -WALK_BOB_VERTICAL_PX)
	_sway_sign *= -1
	_anim_tween = create_tween()
	_anim_tween.tween_method(_set_visual_offset, _visual_offset, target_a, bob_half).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	_anim_tween.tween_method(_set_visual_offset, target_a, Vector2.ZERO, bob_half).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_SINE)
	_anim_tween.finished.connect(func ():
		_anim_tween = null
	)

func _handle_facing(screen_delta: Vector2) -> bool:
	var delta_x: float = screen_delta.x
	if abs(delta_x) <= 0.1:
		return false
	var desired_dir := (1 if delta_x > 0.0 else -1)
	if desired_dir == _facing_dir:
		return false
	var base_x: float = max(0.001, abs(_base_scale.x))
	var current_dir := (1 if scale.x >= 0 else -1)
	if scale.x == 0.0:
		current_dir = _facing_dir
	if _flip_tween:
		_flip_tween.kill()
		_flip_tween = null
	scale = Vector2(base_x * float(current_dir), _base_scale.y)
	var shrink_scale := Vector2(base_x * TURN_FLIP_MIN_SCALE * float(current_dir), _base_scale.y)
	var mid_scale := Vector2(base_x * TURN_FLIP_MIN_SCALE * float(desired_dir), _base_scale.y)
	var target_scale := Vector2(base_x * float(desired_dir), _base_scale.y)
	_flip_tween = create_tween()
	_flip_tween.tween_property(self, "scale", shrink_scale, TURN_PAGE_HALF_TIME).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_SINE)
	_flip_tween.tween_callback(func ():
		scale = mid_scale
	)
	_flip_tween.tween_property(self, "scale", target_scale, TURN_PAGE_HALF_TIME).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	_flip_tween.finished.connect(func ():
		_flip_tween = null
	)
	_facing_dir = desired_dir
	return true

func _snap_to_cell(_force := false) -> void:
	var target_pos := _cell_sprite_position(_cell)
	_set_base_position(target_pos)
	_set_visual_offset(Vector2.ZERO)
	_update_z_index()
	_refresh_debug_draw()

func _cell_sprite_position(cell: Vector2i) -> Vector2:
	var z_top := _surface_top_z(cell)
	var iso := MapUtilsRef.project_iso3d(
		_map_ref,
		float(cell.x),
		float(cell.y),
		float(z_top)
	)
	return iso - _anchor + _texture_center

func _surface_top_z(cell: Vector2i) -> int:
	var z_surf := MapUtilsRef.surface_z(_map_ref, cell.x, cell.y, 0)
	if _map_ref and _map_ref.has_method("get_max_elevation"):
		var z_max := int(_map_ref.call("get_max_elevation"))
		return clampi(z_surf + 1, 0, z_max)
	return z_surf + 1

func _draw() -> void:
	if not DEBUG_SHOW_COLLISION:
		return
	if _debug_region_size == Vector2.ZERO:
		return
	var rect := Rect2(-_texture_center, _debug_region_size)
	draw_rect(rect, DEBUG_COLLISION_COLOR, false, DEBUG_LINE_WIDTH)
	var cross_half := 4.0
	var pivot := _debug_pivot
	draw_line(pivot + Vector2(-cross_half, 0.0), pivot + Vector2(cross_half, 0.0), DEBUG_PIVOT_COLOR, DEBUG_LINE_WIDTH)
	draw_line(pivot + Vector2(0.0, -cross_half), pivot + Vector2(0.0, cross_half), DEBUG_PIVOT_COLOR, DEBUG_LINE_WIDTH)

func _update_z_index() -> void:
	var z_top := _surface_top_z(_sort_cell)
	var sort_key := MapUtilsRef.sort_key(_sort_cell.x, _sort_cell.y, z_top)
	z_index = clampi(sort_key + _sort_bias + Z_INDEX_LIFT, RenderingServer.CANVAS_ITEM_Z_MIN, RenderingServer.CANVAS_ITEM_Z_MAX)

func _refresh_debug_draw() -> void:
	if DEBUG_SHOW_COLLISION:
		queue_redraw()

func _set_base_position(value: Vector2) -> void:
	_base_position = value
	_apply_visual_position()

func refresh_map_bounds(new_map_ref: Node = null) -> void:
	var target_map := (new_map_ref if new_map_ref != null else _map_ref)
	if target_map == null:
		return
	if target_map != _map_ref:
		_bind_map_signals(target_map)
	_map_ref = target_map
	_map_dims = _resolve_map_dimensions(_map_ref)
	_cell = _clamp_cell_to_bounds(_cell)
	_wander_center = _clamp_cell_to_bounds(_wander_center)
	_sort_cell = _cell
	_pending_sort_cell = _cell
	_snap_to_cell(true)

func _resolve_map_dimensions(map_ref: Node) -> Vector2i:
	if map_ref == null:
		return Vector2i.ZERO
	if map_ref.has_method("get_dimensions"):
		var dims_variant = map_ref.call("get_dimensions")
		if dims_variant is Vector2i:
			return dims_variant
		if dims_variant is Vector2:
			return Vector2i(int(dims_variant.x), int(dims_variant.y))
	return Vector2i.ZERO

func _clamp_cell_to_bounds(cell: Vector2i) -> Vector2i:
	if _map_dims.x <= 0 or _map_dims.y <= 0:
		return cell
	return Vector2i(
		clampi(cell.x, 0, _map_dims.x - 1),
		clampi(cell.y, 0, _map_dims.y - 1)
	)

func _bind_map_signals(map_ref: Node) -> void:
	_unbind_map_signals()
	if map_ref == null:
		return
	_map_signal_owner = map_ref
	var started_cb := Callable(self, "_on_map_rebuild_started")
	var finished_cb := Callable(self, "_on_map_rebuild_finished")
	if map_ref.has_signal("map_rebuild_started") and not map_ref.map_rebuild_started.is_connected(started_cb):
		map_ref.map_rebuild_started.connect(started_cb, CONNECT_REFERENCE_COUNTED)
	if map_ref.has_signal("map_rebuild_finished") and not map_ref.map_rebuild_finished.is_connected(finished_cb):
		map_ref.map_rebuild_finished.connect(finished_cb, CONNECT_REFERENCE_COUNTED)

func _unbind_map_signals() -> void:
	if _map_signal_owner == null or not is_instance_valid(_map_signal_owner):
		_map_signal_owner = null
		return
	var started_cb := Callable(self, "_on_map_rebuild_started")
	var finished_cb := Callable(self, "_on_map_rebuild_finished")
	if _map_signal_owner.has_signal("map_rebuild_started") and _map_signal_owner.map_rebuild_started.is_connected(started_cb):
		_map_signal_owner.map_rebuild_started.disconnect(started_cb)
	if _map_signal_owner.has_signal("map_rebuild_finished") and _map_signal_owner.map_rebuild_finished.is_connected(finished_cb):
		_map_signal_owner.map_rebuild_finished.disconnect(finished_cb)
	_map_signal_owner = null

func _on_map_rebuild_started() -> void:
	if _map_refresh_pending:
		return
	_map_refresh_pending = true
	_set_wander_enabled(false)

func _on_map_rebuild_finished() -> void:
	if not _map_refresh_pending:
		return
	_map_refresh_pending = false
	refresh_map_bounds()
	_set_wander_enabled(true)

func _set_wander_enabled(enabled: bool) -> void:
	if _wander_enabled == enabled:
		return
	_wander_enabled = enabled
	if enabled:
		_schedule_next_move()
	else:
		_stop_active_motion()

func _stop_active_motion() -> void:
	if _move_timer and is_instance_valid(_move_timer):
		if _move_timer.timeout.is_connected(_on_move_timer_timeout):
			_move_timer.timeout.disconnect(_on_move_timer_timeout)
		_move_timer = null
	if _active_tween:
		_active_tween.kill()
		_active_tween = null
	if _anim_tween:
		_anim_tween.kill()
		_anim_tween = null
	if _flip_tween:
		_flip_tween.kill()
		_flip_tween = null
	_clear_hop_timer()

func _set_visual_offset(value: Vector2) -> void:
	_visual_offset = value
	_apply_visual_position()

func _apply_visual_position() -> void:
	position = _base_position + _visual_offset

func _clear_hop_timer() -> void:
	if _hop_pause_timer and is_instance_valid(_hop_pause_timer):
		if _hop_pause_timer.timeout.is_connected(_on_hop_pause_timeout):
			_hop_pause_timer.timeout.disconnect(_on_hop_pause_timeout)
		_hop_pause_timer = null

func _should_delay_sort(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	var from_key := _sort_key_for_cell(from_cell)
	var to_key := _sort_key_for_cell(to_cell)
	return to_key < from_key

func _sort_key_for_cell(cell: Vector2i) -> int:
	var z_top := _surface_top_z(cell)
	return MapUtilsRef.sort_key(cell.x, cell.y, z_top)
