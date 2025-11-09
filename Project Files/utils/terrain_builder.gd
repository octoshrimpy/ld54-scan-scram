extends RefCounted
class_name TerrainBuilder

var map: PlanetMap

var top_noise: FastNoiseLite = FastNoiseLite.new()
var carpet_noise: FastNoiseLite = FastNoiseLite.new()
var grad_noise: FastNoiseLite = FastNoiseLite.new()
var height_u1: FastNoiseLite = FastNoiseLite.new()
var height_u2: FastNoiseLite = FastNoiseLite.new()
var detail_noise: FastNoiseLite = FastNoiseLite.new()

var _water_active: bool = false
var _water_level: int = -1
var _water_columns: Array = []
var _rng := RandomNumberGenerator.new()

func setup(map_ref: PlanetMap) -> void:
	map = map_ref
	_configure_noises()

func apply_seed(new_seed: int) -> void:
	top_noise.seed = new_seed ^ 0xABCDEF01
	carpet_noise.seed = new_seed ^ 0xBADC0DED
	grad_noise.seed = new_seed ^ 0x13579BDF
	height_u1.seed = new_seed ^ 0x0F0F0F0F
	height_u2.seed = new_seed ^ 0xF00DFACE
	detail_noise.seed = new_seed ^ 0x2468ACE1
	_rng.seed = new_seed ^ 0x5BD1E995

func build_terrain() -> Array:
	_water_columns.clear()
	for _y in range(map.H):
		var row: Array = []
		row.resize(map.W)
		for i in range(map.W):
			row[i] = false
		_water_columns.append(row)

	var surfaces: Array = []
	var grass_mask: Array = []
	var min_grass: int = map.Z_MAX
	var max_grass: int = 0
	var grass_found := false
	for y in range(map.H):
		var row_surf: Array = []
		var row_grass: Array = []
		for x in range(map.W):
			var z_surf: int = _surface_z_at(x, y)
			row_surf.append(z_surf)
			var grassy := is_grass_topped(x, y, z_surf)
			row_grass.append(grassy)
			if grassy:
				grass_found = true
				min_grass = min(min_grass, z_surf)
				max_grass = max(max_grass, z_surf)
		surfaces.append(row_surf)
		grass_mask.append(row_grass)

	_water_active = false
	_water_level = -1
	var water_spawn := _compute_water_activity(grass_found, min_grass, max_grass)
	_water_active = water_spawn["active"]
	_water_level = water_spawn["level"]

	var atlas_stone := map._stone_atlas()
	var atlas_dirt := map._dirt_atlas()
	var atlas_grass := map._grassy_dirt_atlas()
	var atlas_water_surface := map._water_surface_atlas()
	var atlas_water_depth := map._water_depth_atlas()
	var water_tint := Color(1.0, 1.0, 1.0, map.WATER_ALPHA)

	for y in range(map.H):
		var row_surf: Array = surfaces[y]
		var row_grass: Array = grass_mask[y]
		var water_row: Array = _water_columns[y]
		for x in range(map.W):
			var z_surf: int = row_surf[x]
			var column_has_water := false
			if _water_active:
				var water_cap: int = min(_water_level, map.Z_MAX)
				for z in range(0, water_cap + 1):
					if z > z_surf:
						var atlas_xy := (atlas_water_surface if z == water_cap else atlas_water_depth)
						var mat := (map._water_surface_material if z == water_cap else map._water_depth_material)
						map._place_sprite(atlas_xy, x, y, z, water_tint, mat)
						column_has_water = true
			water_row[x] = column_has_water
			var has_grass_top := bool(row_grass[x]) and not column_has_water
			if has_grass_top:
				map._place_sprite(atlas_grass, x, y, z_surf)
				var n_carpet: float = 0.5 + 0.5 * carpet_noise.get_noise_2d(float(x), float(y))
				if n_carpet > map.CARPET_PERLIN_THRESH and z_surf + 1 <= map.Z_MAX:
					map._place_sprite(map._grass_blade_atlas(), x, y, z_surf + 1, Color(1, 1, 1, 1), map._grass_blade_material)
			else:
				map._place_sprite(atlas_dirt, x, y, z_surf)

			for z in range(max(0, z_surf - map.DIRT_CAP_LAYERS), z_surf):
				map._place_sprite(atlas_dirt, x, y, z)

			var grad_top: int = max(0, z_surf - map.DIRT_CAP_LAYERS - 1)
			for z in range(0, grad_top + 1):
				var base_p: float = float(z) / float(max(1, grad_top)) + map.GRADIENT_BIAS
				var jitter: float = map.GRADIENT_NOISE_AMPL * (0.5 + 0.5 * grad_noise.get_noise_2d(float(x), float(y)))
				var p_dirt: float = clampf(base_p + (jitter - map.GRADIENT_NOISE_AMPL * 0.5), 0.0, 1.0)
				var atlas := (atlas_dirt if _rng.randf() < p_dirt else atlas_stone)
				map._place_sprite(atlas, x, y, z)

			_spawn_surface_detail(x, y, z_surf)
		_water_columns[y] = water_row
	return surfaces

func has_active_water() -> bool:
	return _water_active

func is_water_column(x: int, y: int) -> bool:
	if not _water_active:
		return false
	if y < 0 or y >= _water_columns.size():
		return false
	var row: Array = _water_columns[y]
	if x < 0 or x >= row.size():
		return false
	return bool(row[x])

func surface_z_at(x: int, y: int) -> int:
	return _surface_z_at(x, y)

func is_grass_topped(x: int, y: int, z: int) -> bool:
	if z != _surface_z_at(x, y):
		return false
	if is_water_column(x, y):
		return false
	var n_grass: float = 0.5 + 0.5 * top_noise.get_noise_2d(float(x), float(y))
	return n_grass > map.TOP_PERLIN_THRESH

func _configure_noises() -> void:
	top_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	top_noise.frequency = map.TOP_PERLIN_FREQ
	top_noise.fractal_octaves = map.TOP_PERLIN_OCTAVES
	top_noise.fractal_gain = map.TOP_PERLIN_GAIN
	top_noise.fractal_lacunarity = map.TOP_PERLIN_LACUN

	carpet_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	carpet_noise.frequency = map.CARPET_PERLIN_FREQ
	carpet_noise.fractal_octaves = map.CARPET_PERLIN_OCTAVES
	carpet_noise.fractal_gain = map.CARPET_PERLIN_GAIN
	carpet_noise.fractal_lacunarity = map.CARPET_PERLIN_LACUN

	grad_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	grad_noise.frequency = map.GRADIENT_NOISE_FREQ
	grad_noise.fractal_octaves = 2
	grad_noise.fractal_gain = 0.5
	grad_noise.fractal_lacunarity = 2.0

	detail_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	detail_noise.frequency = map.DETAIL_NOISE_FREQ
	detail_noise.fractal_octaves = 2
	detail_noise.fractal_gain = 0.5
	detail_noise.fractal_lacunarity = 2.0

	for n in [height_u1, height_u2]:
		n.noise_type = FastNoiseLite.TYPE_PERLIN
		n.frequency = 1.0
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
		n.fractal_octaves = 1
		n.fractal_gain = 1.0
		n.fractal_lacunarity = 2.0

func _fbm_height(noise: FastNoiseLite, x: float, y: float, base_freq: float) -> float:
	var freq := base_freq
	var amplitude := 1.0
	var total := 0.0
	var norm := 0.0
	var octave_count: int = max(1, map.height_octaves)
	for _i in range(octave_count):
		total += noise.get_noise_2d(x * freq, y * freq) * amplitude
		norm += amplitude
		freq *= map.height_lacun
		amplitude *= map.height_gain
	return (total / norm) if norm > 0.0 else 0.0

func _surface_z_at(x: int, y: int) -> int:
	var xf := float(x)
	var yf := float(y)
	var base := _fbm_height(height_u1, xf, yf, map.height_freq)
	var detail := _fbm_height(height_u2, xf, yf, map.height_freq * map.height_detail_freq_mult)
	var combined := lerpf(base, detail, clampf(map.height_detail_weight, 0.0, 1.0))
	var normalized := clampf(0.5 + 0.5 * combined, 0.0, 1.0)
	normalized = pow(normalized, map.height_shape_exp)
	var min_t := clampf(map.height_min_t, 0.0, map.HEIGHT_MAX_T_CAP)
	var max_t := clampf(map.height_max_t, min_t + 1e-5, map.HEIGHT_MAX_T_CAP)
	var zf: float = lerpf(min_t * float(map.Z_MAX), max_t * float(map.Z_MAX), normalized)
	return clampi(int(round(zf)), 0, map.Z_MAX)

func _detail_offset(x: int, y: int, weight: float) -> Vector2:
	var jitter_u := detail_noise.get_noise_3d(float(x), float(y), 17.0)
	var jitter_v := detail_noise.get_noise_3d(float(x), float(y), -41.0)
	var scale_factor: float = map.DETAIL_JITTER_PX * clampf(0.25 + weight * 0.75, 0.0, 1.0)
	return Vector2(jitter_u, jitter_v) * scale_factor

func _spawn_surface_detail(x: int, y: int, z_surf: int) -> void:
	if is_water_column(x, y) or z_surf < map.SEA_Z:
		return
	var n := 0.5 + 0.5 * detail_noise.get_noise_2d(float(x), float(y))
	if n > map.DETAIL_GRASS_THRESH and z_surf + 1 <= map.Z_MAX:
		var weight := clampf((n - map.DETAIL_GRASS_THRESH) / max(0.001, 1.0 - map.DETAIL_GRASS_THRESH), 0.0, 1.0)
		var offset := _detail_offset(x, y, weight)
		var scale_f := lerpf(0.85, 1.2, weight)
		var tint := Color(1.0, lerpf(0.9, 1.0, weight), 1.0, 0.9 + 0.1 * weight)
		var z_top: int = min(z_surf + 1, map.Z_MAX)
		map._place_detail_sprite(map._grass_blade_atlas(), x, y, z_top, offset, Vector2(scale_f, scale_f), 0.05 * (weight - 0.5), tint)
		if n > map.DETAIL_DENSE_THRESH:
			var weight2 := clampf((n - map.DETAIL_DENSE_THRESH) / max(0.001, 1.0 - map.DETAIL_DENSE_THRESH), 0.0, 1.0)
			var offset2 := _detail_offset(x + 37, y + 19, weight2) * 0.5
			var scale_f2 := lerpf(0.7, 1.0, weight2)
			map._place_detail_sprite(map._grass_blade_atlas(), x, y, z_top, offset2, Vector2(scale_f2, scale_f2), -0.05 * (weight2 - 0.5), tint)
	elif n < map.DETAIL_STONE_THRESH:
		var weight_stone := clampf((map.DETAIL_STONE_THRESH - n) / max(0.001, map.DETAIL_STONE_THRESH), 0.0, 1.0)
		var offset_stone := _detail_offset(x + 11, y + 53, weight_stone) * 0.6
		var scale_s := lerpf(0.6, 0.95, weight_stone)
		var tint_s := Color(lerpf(0.8, 1.0, weight_stone), lerpf(0.8, 0.95, weight_stone), lerpf(0.8, 0.9, weight_stone), 0.85 + 0.15 * weight_stone)
		map._place_detail_sprite(map._stone_pebble_atlas(), x, y, z_surf, offset_stone, Vector2(scale_s, scale_s), 0.0, tint_s)

func _compute_water_activity(grass_found: bool, min_grass: int, max_grass: int) -> Dictionary:
	if not grass_found:
		return {"active": false, "level": -1}
	var min_percent := map.water_percent_min
	var max_percent := map.water_percent_max
	if max_percent <= 0.0:
		return {"active": false, "level": -1}
	if _rng.randf() >= clampf(map.water_spawn_chance, 0.0, 1.0):
		return {"active": false, "level": -1}
	var span: int = max_grass - min_grass
	var percent: float = (max_percent if is_equal_approx(min_percent, max_percent) else _rng.randf_range(min_percent, max_percent))
	var level_f := float(min_grass) + float(span) * percent
	var water_level := clampi(int(round(level_f)), 0, map.Z_MAX)
	return {"active": true, "level": water_level}
