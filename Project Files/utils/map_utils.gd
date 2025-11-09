extends Object
class_name MapUtils

# Shared helpers for querying the planet map node from gameplay generators.

static func surface_z(map: Node, x: int, y: int, default_value: int = -1) -> int:
	if map == null:
		return default_value
	if map.has_method("surface_z_at"):
		return int(map.call("surface_z_at", x, y))
	return default_value

static func project_iso3d(map: Node, x: float, y: float, z: float) -> Vector2:
	if map == null:
		return Vector2.ZERO
	if map.has_method("project_iso3d"):
		return map.call("project_iso3d", x, y, z)
	if map.has_method("_project_iso3d"):
		return map.call("_project_iso3d", x, y, z)
	return Vector2.ZERO

static func column_bottom_world(map: Node, x: int, y: int, z: int) -> Vector2:
	return project_iso3d(map, float(x), float(y), float(z))

static func sort_key(x: int, y: int, z: int) -> int:
	# Order canvas items by projected screen Y (iso uses (x + y)) with per-tile uniqueness.
	var diag := x + y
	var raw := diag * 64 + x + z
	var biased := raw - 4096
	return clampi(biased, RenderingServer.CANVAS_ITEM_Z_MIN, RenderingServer.CANVAS_ITEM_Z_MAX)

static func is_grass_topped(map: Node, x: int, y: int, z: int) -> bool:
	if map != null and map.has_method("is_grass_topped"):
		return bool(map.call("is_grass_topped", x, y, z))
	return true

static func column_has_water(map: Node, x: int, y: int) -> bool:
	if map != null and map.has_method("is_water_column"):
		return bool(map.call("is_water_column", x, y))
	return false
