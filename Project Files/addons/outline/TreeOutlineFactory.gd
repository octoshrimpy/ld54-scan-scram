extends RefCounted
class_name TreeOutlineFactory

const HoverOutlineSpriteScript := preload("res://addons/outline/hover_outline_sprite.gd")

var outline_color: Color = Color(0.05, 0.8, 0.5, 0.9)
var outline_thickness_px: int = 1
var padding_px: int = 3
var hover_margin_px: float = 5.0
var hover_only: bool = true
var hover_alpha_threshold: float = 0.65

func bake_group(
	group: Node2D,
	atlas_image: Image,
	target_parent: Node,
	final_z_index: int,
	metadata: Dictionary = {}
) -> HoverOutlineSprite:
	if group == null or target_parent == null:
		return null

	var sprites := _collect_sprites(group)
	if sprites.is_empty():
		group.queue_free()
		return null

	var content_rect := _measure_bounds(sprites)
	if content_rect.size.x <= 0.0 or content_rect.size.y <= 0.0:
		group.queue_free()
		return null

	var draw_rect := content_rect.grow(float(max(0, padding_px)))
	var base_image := _compose_image(sprites, atlas_image, draw_rect)
	var base_texture := ImageTexture.create_from_image(base_image)
	var tex_size := Vector2(base_image.get_width(), base_image.get_height())

	var outline_texture: Texture2D = null
	if outline_thickness_px > 0 and outline_color.a > 0.0:
		var outline_image := _build_outline_image(base_image)
		outline_texture = ImageTexture.create_from_image(outline_image)

	var hover_sprite := HoverOutlineSpriteScript.new()
	var local_rect := Rect2(Vector2.ZERO, tex_size)
	hover_sprite.configure(
		base_texture,
		outline_texture,
		local_rect,
		hover_margin_px,
		hover_only,
		hover_alpha_threshold,
		metadata,
		base_image
	)
	target_parent.add_child(hover_sprite)
	hover_sprite.global_position = draw_rect.position
	hover_sprite.z_index = final_z_index
	hover_sprite.z_as_relative = false

	group.queue_free()
	return hover_sprite

func _collect_sprites(group: Node2D) -> Array[Sprite2D]:
	var sprites: Array[Sprite2D] = []
	for child in group.get_children():
		if child is Sprite2D:
			sprites.append(child)
	return sprites

func _measure_bounds(sprites: Array[Sprite2D]) -> Rect2:
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF

	for spr in sprites:
		var size := _sprite_pixel_size(spr)
		var pos := spr.global_position
		min_x = min(min_x, pos.x)
		min_y = min(min_y, pos.y)
		max_x = max(max_x, pos.x + size.x)
		max_y = max(max_y, pos.y + size.y)

	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))

func _sprite_pixel_size(spr: Sprite2D) -> Vector2:
	if spr.region_enabled:
		return spr.region_rect.size
	if spr.texture != null:
		return spr.texture.get_size()
	return Vector2.ZERO

func _compose_image(
	sprites: Array[Sprite2D],
	atlas_image: Image,
	draw_rect: Rect2
) -> Image:
	var width := int(ceil(draw_rect.size.x))
	var height := int(ceil(draw_rect.size.y))
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	for spr in sprites:
		_blit_sprite(image, draw_rect.position, spr, atlas_image)

	return image

func _blit_sprite(
	target: Image,
	draw_origin: Vector2,
	spr: Sprite2D,
	atlas_image: Image
) -> void:
	var sample := atlas_image
	if sample == null:
		var tex := spr.texture
		if tex == null:
			return
		sample = tex.get_image()
		if sample == null:
			return

	var src_rect := _sprite_region(spr, sample)
	if src_rect.size == Vector2i.ZERO:
		return

	var dest_origin := spr.global_position - draw_origin
	var base_x := int(floor(dest_origin.x))
	var base_y := int(floor(dest_origin.y))

	var modulate := _combined_modulate(spr)

	for sy in range(src_rect.size.y):
		var dy := base_y + sy
		if dy < 0 or dy >= target.get_height():
			continue
		for sx in range(src_rect.size.x):
			var dx := base_x + sx
			if dx < 0 or dx >= target.get_width():
				continue
			var src_px := sample.get_pixel(src_rect.position.x + sx, src_rect.position.y + sy)
			if src_px.a <= 0.0:
				continue
			var color := _apply_modulate(src_px, modulate)
			_blend_pixel(target, dx, dy, color)

func _sprite_region(spr: Sprite2D, sample: Image) -> Rect2i:
	if spr.region_enabled:
		return Rect2i(spr.region_rect.position, spr.region_rect.size)
	if spr.texture != null:
		var size := spr.texture.get_size()
		return Rect2i(Vector2i.ZERO, Vector2i(int(size.x), int(size.y)))
	if sample != null:
		return Rect2i(Vector2i.ZERO, Vector2i(sample.get_width(), sample.get_height()))
	return Rect2i()

func _combined_modulate(spr: Sprite2D) -> Color:
	var c := spr.self_modulate
	var parent_mod := spr.modulate
	return Color(
		c.r * parent_mod.r,
		c.g * parent_mod.g,
		c.b * parent_mod.b,
		c.a * parent_mod.a
	)

func _apply_modulate(color: Color, modulate: Color) -> Color:
	return Color(
		color.r * modulate.r,
		color.g * modulate.g,
		color.b * modulate.b,
		color.a * modulate.a
	)

func _blend_pixel(target: Image, x: int, y: int, color: Color) -> void:
	if color.a <= 0.0:
		return
	var dst := target.get_pixel(x, y)
	var src_a := color.a
	var dst_a := dst.a

	var out_a := src_a + dst_a * (1.0 - src_a)
	var src_rgb := Vector3(color.r * src_a, color.g * src_a, color.b * src_a)
	var dst_rgb := Vector3(dst.r * dst_a, dst.g * dst_a, dst.b * dst_a)
	var premul := src_rgb + dst_rgb * (1.0 - src_a)
	var out_rgb := Vector3.ZERO
	if out_a > 0.0:
		out_rgb = premul / out_a

	target.set_pixel(x, y, Color(out_rgb.x, out_rgb.y, out_rgb.z, out_a))

func _build_outline_image(base_image: Image) -> Image:
	var w := base_image.get_width()
	var h := base_image.get_height()
	var outline := Image.create(w, h, false, Image.FORMAT_RGBA8)
	if outline_thickness_px <= 0 or outline_color.a <= 0.0:
		return outline

	var radius := max(1, outline_thickness_px)
	for y in range(h):
		for x in range(w):
			var alpha := base_image.get_pixel(x, y).a
			if alpha > 0.0:
				continue
			var max_neighbor := 0.0
			for oy in range(-radius, radius + 1):
				var ny := y + oy
				if ny < 0 or ny >= h:
					continue
				for ox in range(-radius, radius + 1):
					var nx := x + ox
					if nx < 0 or nx >= w:
						continue
					if ox == 0 and oy == 0:
						continue
					if abs(ox) + abs(oy) > radius:
						continue
					if ox != 0 and oy != 0:
						continue
					var neighbor_a := base_image.get_pixel(nx, ny).a
					if neighbor_a > max_neighbor:
						max_neighbor = neighbor_a
			if max_neighbor <= 0.0:
				continue
			var c := outline_color
			c.a *= max_neighbor
			outline.set_pixel(x, y, c)

	return outline
