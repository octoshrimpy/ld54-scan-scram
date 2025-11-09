extends RefCounted
class_name RedshirtSystem

const MapUtilsRef := preload("res://utils/map_utils.gd")
const RedshirtSpawnerScript := preload("res://utils/redshirt_spawner.gd")
const RedshirtAgentScript: GDScript = preload("res://utils/redshirt_agent.gd")

var _map: Node
var _spawner := RedshirtSpawnerScript.new()
var _draw_root: Node2D
var _atlas_src: TileSetAtlasSource
var _atlas_tex: Texture2D
var _active_redshirts: Array[Node] = []
var _focus_vec: Vector2 = Vector2.ZERO
var _focus_tween: Tween
var _camera_focus_tween: Tween
var _focus_overlay: Node2D
var _focus_circle: Line2D
var _current_wander_radius: int = 0
var _camera_centered_by_spawn: bool = false
var _rng := RandomNumberGenerator.new()

func setup(map_ref: Node) -> void:
	_map = map_ref
	_current_wander_radius = _default_wander_radius()
	_ensure_focus_overlay()
	_rng.randomize()

func set_draw_root(root: Node2D) -> void:
	_draw_root = root

func set_atlas(src: TileSetAtlasSource, tex: Texture2D) -> void:
	_atlas_src = src
	_atlas_tex = tex

func clear_for_rebuild() -> void:
	_camera_centered_by_spawn = false
	_current_wander_radius = _default_wander_radius()
	if _focus_tween != null:
		_focus_tween.kill()
		_focus_tween = null
	if _camera_focus_tween != null:
		_camera_focus_tween.kill()
		_camera_focus_tween = null
	_despawn_redshirts()

func camera_centered_by_spawn() -> bool:
	return _camera_centered_by_spawn

func spawn_redshirts(surfaces: Array) -> void:
	if _spawner == null or _atlas_src == null or _atlas_tex == null or _draw_root == null:
		return
	var placements = _spawner.spawn_redshirts(
		Callable(),
		Callable(_map, "is_water_column"),
		surfaces,
		_map.W,
		_map.H,
		_map.Z_MAX
	)
	if placements.is_empty():
		return
	var pending: Array[Dictionary] = []
	var positions: Array[Vector2i] = []
	for placement_variant in placements:
		if typeof(placement_variant) != TYPE_DICTIONARY:
			continue
		var placement: Dictionary = placement_variant
		var atlas_xy: Vector2i = placement.get("atlas", Vector2i.ZERO)
		var pos: Vector2i = placement.get("pos", Vector2i.ZERO)
		var flip_h: bool = bool(placement.get("flip_h", false))
		pending.append({
			"atlas": atlas_xy,
			"pos": pos,
			"flip_h": flip_h
		})
		positions.append(pos)
	if pending.is_empty():
		return
	var center_cell := _cluster_center_cell(positions)
	_move_redshirt_focus(center_cell, true)
	_schedule_redshirt_beam(center_cell, pending, positions, surfaces)

func refresh_focus_indicator() -> void:
	_update_epicenter_indicator()

func handle_dressing_highlight(cell: Vector2i) -> void:
	_set_global_wander_radius(_map.REDSHIRT_WANDER_RADIUS_CLICK)
	_move_redshirt_focus(cell)

func set_seed(seed: int) -> void:
	_rng.seed = seed
	if _spawner != null and _spawner.has_method("set_seed"):
		_spawner.set_seed(seed ^ 0x9E3779B9)

func _schedule_redshirt_beam(center_cell: Vector2i, pending: Array, positions: Array[Vector2i], surfaces: Array) -> void:
	var pending_copy: Array = []
	for entry_variant in pending:
		if entry_variant is Dictionary:
			pending_copy.append((entry_variant as Dictionary).duplicate(true))
	var positions_copy: Array[Vector2i] = []
	for cell_variant in positions:
		positions_copy.append(cell_variant)
	_focus_camera_on_cell(center_cell, _map.BEAM_CAMERA_FOCUS_TIME)
	if _map.BEAM_SPAWN_DELAY <= 0.0:
		_finalize_redshirt_beam(center_cell, pending_copy, positions_copy, surfaces)
		return
	var tree := _map.get_tree()
	if tree == null:
		_finalize_redshirt_beam(center_cell, pending_copy, positions_copy, surfaces)
		return
	var timer := tree.create_timer(_map.BEAM_SPAWN_DELAY)
	timer.timeout.connect(func ():
		_finalize_redshirt_beam(center_cell, pending_copy, positions_copy, surfaces)
	, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

func _finalize_redshirt_beam(center_cell: Vector2i, pending: Array, positions: Array[Vector2i], _surfaces: Array) -> void:
	_play_beam_down_effect(center_cell, positions.size())
	var delay: float = max(0.0, _map.BEAM_REDSHIRT_DELAY)
	if delay <= 0.0:
		_spawn_redshirt_batch(pending, center_cell)
		return
	var tree := _map.get_tree()
	if tree == null:
		_spawn_redshirt_batch(pending, center_cell)
		return
	var timer := tree.create_timer(delay)
	timer.timeout.connect(func ():
		_spawn_redshirt_batch(pending, center_cell)
	, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

func _spawn_redshirt_batch(pending: Array, center_cell: Vector2i) -> void:
	for entry_variant in pending:
		var entry: Dictionary = entry_variant
		var atlas_xy: Vector2i = entry.get("atlas", Vector2i.ZERO)
		var pos: Vector2i = entry.get("pos", Vector2i.ZERO)
		var flip_h: bool = bool(entry.get("flip_h", false))
		_place_redshirt_sprite(atlas_xy, pos.x, pos.y, flip_h, center_cell, _random_redshirt_radius())
	_camera_centered_by_spawn = true

func _place_redshirt_sprite(
	atlas_xy: Vector2i,
	x: int,
	y: int,
	flip_h: bool,
	wander_center: Vector2i,
	wander_radius: int
) -> void:
	if _atlas_src == null or _atlas_tex == null or _draw_root == null:
		return
	var region: Rect2i = _atlas_src.get_tile_texture_region(atlas_xy)
	if region.size == Vector2i.ZERO:
		return
	var agent: Node = RedshirtAgentScript.new()
	var anchor := Vector2(_map._tile_w * 0.5, _map._tile_h)
	_draw_root.add_child(agent)
	agent.configure(
		_map,
		_atlas_tex,
		region,
		Vector2i(x, y),
		anchor,
		_map.REDSHIRT_SORT_BIAS,
		wander_center,
		wander_radius,
		_map.REDSHIRT_MOVE_INTERVAL,
		_map.REDSHIRT_SECONDS_PER_TILE,
		flip_h
	)
	_register_redshirt(agent)
	var tint: Color = agent.modulate
	agent.modulate = Color(tint.r, tint.g, tint.b, 0.0)
	var fade: Tween = agent.create_tween()
	fade.tween_property(agent, "modulate:a", 1.0, _map.REDSHIRT_SPAWN_FADE).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)

func _focus_camera_on_cell(center_cell: Vector2i, duration: float) -> void:
	if _map.cam == null:
		return
	var z_top: int = _map.surface_z_at(center_cell.x, center_cell.y)
	var target: Vector2 = _map.project_iso3d(float(center_cell.x), float(center_cell.y), float(z_top + 1))
	if duration <= 0.0:
		if _camera_focus_tween != null:
			_camera_focus_tween.kill()
			_camera_focus_tween = null
		_map.cam.global_position = target
		_camera_centered_by_spawn = true
		return
	_camera_centered_by_spawn = false
	if _camera_focus_tween != null:
		_camera_focus_tween.kill()
	_camera_focus_tween = _map.cam.create_tween()
	_camera_focus_tween.tween_property(_map.cam, "global_position", target, duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	_camera_focus_tween.finished.connect(func ():
		_camera_centered_by_spawn = true
		_camera_focus_tween = null
	, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

func _cluster_center_cell(cells: Array[Vector2i]) -> Vector2i:
	if cells.is_empty():
		return Vector2i(_map.W >> 1, _map.H >> 1)
	var accum_x := 0.0
	var accum_y := 0.0
	for cell_variant in cells:
		var cell: Vector2i = cell_variant
		accum_x += float(cell.x)
		accum_y += float(cell.y)
	var inv := 1.0 / float(max(1, cells.size()))
	var dims: Vector2i = _map.get_dimensions()
	var cx := clampi(int(round(accum_x * inv)), 0, max(0, dims.x - 1))
	var cy := clampi(int(round(accum_y * inv)), 0, max(0, dims.y - 1))
	return Vector2i(cx, cy)

func _register_redshirt(agent: Node) -> void:
	if agent == null:
		return
	_active_redshirts.append(agent)
	var focus_cell := Vector2i(int(round(_focus_vec.x)), int(round(_focus_vec.y)))
	if agent.has_method("set_wander_center"):
		agent.set_wander_center(focus_cell)
	var cleanup := Callable(self, "_on_redshirt_tree_exit").bind(agent)
	if agent.tree_exited.is_connected(cleanup):
		return
	agent.tree_exited.connect(cleanup, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

func _move_redshirt_focus(target_cell: Vector2i, immediate: bool = false) -> void:
	if _map == null:
		return
	var clamped: Vector2i = _map._clamp_cell(target_cell)
	var target_vec := Vector2(float(clamped.x), float(clamped.y))
	if immediate:
		if _focus_tween != null:
			_focus_tween.kill()
			_focus_tween = null
		_apply_redshirt_focus(target_vec)
		return
	if _focus_tween != null:
		_focus_tween.kill()
	_focus_tween = _map.create_tween()
	_focus_tween.tween_method(_apply_redshirt_focus, _focus_vec, target_vec, _map.REDSHIRT_FOCUS_LERP_TIME).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	_focus_tween.finished.connect(func ():
		_focus_tween = null
	, CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED)

func _apply_redshirt_focus(value: Vector2) -> void:
	_focus_vec = value
	var cell := Vector2i(int(round(value.x)), int(round(value.y)))
	_update_agent_wander_centers(cell)
	_update_epicenter_indicator()

func _update_agent_wander_centers(cell: Vector2i) -> void:
	for i in range(_active_redshirts.size() - 1, -1, -1):
		var agent_variant: Variant = _active_redshirts[i]
		var agent: Node = agent_variant
		if agent == null or not is_instance_valid(agent):
			_active_redshirts.remove_at(i)
			continue
		if agent.has_method("set_wander_center"):
			agent.set_wander_center(cell)

func _set_global_wander_radius(radius: int) -> void:
	var new_radius: int = max(1, radius)
	if new_radius == _current_wander_radius:
		return
	_current_wander_radius = new_radius
	for i in range(_active_redshirts.size() - 1, -1, -1):
		var agent_variant: Variant = _active_redshirts[i]
		var agent: Node = agent_variant
		if agent == null or not is_instance_valid(agent):
			_active_redshirts.remove_at(i)
			continue
		if agent.has_method("set_wander_radius"):
			agent.set_wander_radius(new_radius)

func _on_redshirt_tree_exit(agent: Node) -> void:
	if _active_redshirts.has(agent):
		_active_redshirts.erase(agent)

func _despawn_redshirts() -> void:
	for agent in _active_redshirts:
		if is_instance_valid(agent):
			agent.queue_free()
	_active_redshirts.clear()

func _play_beam_down_effect(center_cell: Vector2i, count: int) -> void:
	if _draw_root == null:
		return
	var z_top: int = _map.surface_z_at(center_cell.x, center_cell.y)
	var beam_base_pos: Vector2 = _map.project_iso3d(float(center_cell.x), float(center_cell.y), float(z_top + 1))
	var beam := Node2D.new()
	beam.position = beam_base_pos - Vector2(0.0, _map.BEAM_HEIGHT_PX)
	beam.z_index = MapUtilsRef.sort_key(center_cell.x, center_cell.y, z_top + 2) + 128
	var poly := Polygon2D.new()
	var width: float = _map.BEAM_WIDTH_BASE_PX + float(max(0, count - 1)) * _map.BEAM_WIDTH_PER_AGENT_PX
	var half_w: float = width * 0.5
	poly.polygon = PackedVector2Array([
		Vector2(-half_w, 0.0),
		Vector2(half_w, 0.0),
		Vector2(half_w * 0.5, _map.BEAM_HEIGHT_PX),
		Vector2(-half_w * 0.5, _map.BEAM_HEIGHT_PX),
	])
	poly.modulate = _map.BEAM_COLOR
	poly.antialiased = true
	beam.add_child(poly)
	_draw_root.add_child(beam)
	poly.scale = Vector2(0.3, 0.1)
	var shimmer := CPUParticles2D.new()
	shimmer.position = Vector2(0.0, _map.BEAM_HEIGHT_PX * 0.5)
	shimmer.amount = _map.BEAM_COLUMN_PARTICLE_AMOUNT
	shimmer.lifetime = _map.BEAM_DURATION
	shimmer.one_shot = true
	shimmer.preprocess = _map.BEAM_DURATION
	shimmer.direction = Vector2(0.0, -1.0)
	var shimmer_points := PackedVector2Array()
	for i in range(_map.BEAM_COLUMN_SEGMENTS + 1):
		var t := float(i) / float(max(1, _map.BEAM_COLUMN_SEGMENTS))
		var y_val: float = t * _map.BEAM_HEIGHT_PX
		shimmer_points.append(Vector2(-half_w, y_val))
		shimmer_points.append(Vector2(half_w, y_val))
	shimmer.emission_points = shimmer_points
	shimmer.modulate = Color(_map.BEAM_COLOR.r, _map.BEAM_COLOR.g, _map.BEAM_COLOR.b, 0.8)
	shimmer.emitting = true
	beam.add_child(shimmer)
	var sparks := CPUParticles2D.new()
	sparks.position = Vector2(0.0, _map.BEAM_HEIGHT_PX)
	sparks.amount = _map.BEAM_LANDING_PARTICLE_AMOUNT
	sparks.lifetime = _map.BEAM_LANDING_PARTICLE_LIFETIME
	sparks.one_shot = true
	sparks.preprocess = _map.BEAM_LANDING_PARTICLE_LIFETIME
	sparks.spread = 240.0
	sparks.initial_velocity_min = _map.BEAM_LANDING_PARTICLE_SPEED * 0.5
	sparks.initial_velocity_max = _map.BEAM_LANDING_PARTICLE_SPEED
	sparks.gravity = Vector2(0.0, 420.0)
	sparks.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	sparks.emission_sphere_radius = _map.BEAM_LANDING_PARTICLE_RADIUS
	sparks.modulate = _map.BEAM_COLOR
	sparks.emitting = true
	beam.add_child(sparks)
	var tween := beam.create_tween()
	tween.tween_property(poly, "scale", Vector2(1.0, 1.0), _map.BEAM_DURATION * 0.6).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(poly, "modulate:a", 0.0, _map.BEAM_DURATION * 0.4).set_delay(_map.BEAM_DURATION * 0.3).set_ease(Tween.EASE_IN)
	tween.finished.connect(func ():
		beam.queue_free()
	)

func _random_redshirt_radius() -> int:
	var jitter := 0
	if _map.REDSHIRT_WANDER_RADIUS_JITTER > 0:
		jitter = _rng.randi_range(-_map.REDSHIRT_WANDER_RADIUS_JITTER, _map.REDSHIRT_WANDER_RADIUS_JITTER)
	return max(1, _current_wander_radius + jitter)

func _update_epicenter_indicator() -> void:
	_ensure_focus_overlay()
	if _focus_circle == null or not is_instance_valid(_focus_circle):
		return
	if _focus_overlay == null or not is_instance_valid(_focus_overlay):
		return
	var dims: Vector2i = _map.get_dimensions()
	if dims.x <= 0 or dims.y <= 0:
		return
	var focus_cell := Vector2i(
		clampi(int(round(_focus_vec.x)), 0, dims.x - 1),
		clampi(int(round(_focus_vec.y)), 0, dims.y - 1)
	)
	var z_top: int = _map.surface_z_at(focus_cell.x, focus_cell.y)
	if z_top < 0:
		z_top = 0
	var center: Vector2 = _map.project_iso3d(float(focus_cell.x), float(focus_cell.y), float(z_top + 1))
	_focus_overlay.global_position = center

	var sample_offsets := [
		Vector2i(_map.REDSHIRT_WANDER_RADIUS, 0),
		Vector2i(-_map.REDSHIRT_WANDER_RADIUS, 0),
		Vector2i(0, _map.REDSHIRT_WANDER_RADIUS),
		Vector2i(0, -_map.REDSHIRT_WANDER_RADIUS)
	]
	var sample_cell := focus_cell
	for off in sample_offsets:
		var candidate: Vector2i = focus_cell + off
		if candidate.x >= 0 and candidate.x < dims.x and candidate.y >= 0 and candidate.y < dims.y:
			sample_cell = candidate
			break
	var sample_z: int = _map.surface_z_at(sample_cell.x, sample_cell.y)
	if sample_z < 0:
		sample_z = z_top
	var edge: Vector2 = _map.project_iso3d(float(sample_cell.x), float(sample_cell.y), float(sample_z + 1))
	var radius: float = max(8.0, center.distance_to(edge))
	var pts := PackedVector2Array()
	for i in range(_map.FOCUS_CIRCLE_SEGMENTS):
		var t := float(i) / float(_map.FOCUS_CIRCLE_SEGMENTS) * TAU
		pts.append(Vector2(cos(t), sin(t)) * radius)
	_focus_circle.points = pts

func _ensure_focus_overlay() -> void:
	if _map == null:
		return
	if _focus_overlay == null or not is_instance_valid(_focus_overlay):
		_focus_overlay = Node2D.new()
		_focus_overlay.name = "FocusOverlay"
		_map.add_child(_focus_overlay)
		_focus_overlay.z_index = RenderingServer.CANVAS_ITEM_Z_MAX - 1
	if _focus_circle == null or not is_instance_valid(_focus_circle):
		_focus_circle = Line2D.new()
		_focus_circle.width = _map.FOCUS_CIRCLE_WIDTH
		_focus_circle.default_color = _map.FOCUS_CIRCLE_COLOR
		_focus_circle.antialiased = true
		_focus_circle.closed = true
		_focus_overlay.add_child(_focus_circle)

func _default_wander_radius() -> int:
	return max(1, _map.REDSHIRT_WANDER_RADIUS)
