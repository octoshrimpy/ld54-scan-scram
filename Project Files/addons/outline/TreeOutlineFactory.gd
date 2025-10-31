# res://addons/outline/TreeOutlineFactory.gd
# Godot 4.5.x — Bake a Node2D group of sprites into one outlined Sprite2D.
# Uses color-key masking (for opaque atlas tiles) so the outline hugs the art.

class_name TreeOutlineFactory
extends Node

@export var pad_px: int = 2                      # padding around the baked image
@export var outline_px: int = 1                  # outline thickness in texels
@export var outline_color: Color = Color(0, 0, 0, 1)

# If your atlas background is opaque, set this to that color.
# Example: magenta (1,0,1) or bright green (0,1,0). Tune key_tol as needed.
@export var key_color: Color = Color(0.0, 1.0, 0.0, 1.0)
@export_range(0.0, 0.5, 0.001) var key_tol: float = 0.08

var _outline_shader: Shader
var _outline_material: ShaderMaterial

func _ready() -> void:
	_init_shader()

func _init_shader() -> void:
	if _outline_shader != null:
		return

	_outline_shader = Shader.new()
	_outline_shader.code = """
shader_type canvas_item;

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float outline_px = 1.0;

/* Treat pixels near this color as background (transparent proxy). */
uniform vec3 key_color = vec3(0.0, 1.0, 0.0);
uniform float key_tol = 0.08;

float fg_mask(vec4 texel) {
	// Prefer real alpha if present, otherwise use color distance to key_color
	float a = texel.a;
	float d = distance(texel.rgb, key_color);
	// near key_color -> background (mask 0), far -> foreground (mask 1)
	float from_color = 1.0 - smoothstep(0.0, key_tol, d);
	// We want 1 for FG; take max with alpha
	float fg = max(a, 1.0 - from_color);
	return clamp(fg, 0.0, 1.0);
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float fg = fg_mask(tex);

	ivec2 ts = textureSize(TEXTURE, 0);
	vec2 texel = 1.0 / vec2(float(ts.x), float(ts.y));
	float r = outline_px;

	float n = 0.0;
	n = max(n, fg_mask(texture(TEXTURE, UV + texel * vec2( r,  0))));
	n = max(n, fg_mask(texture(TEXTURE, UV + texel * vec2(-r,  0))));
	n = max(n, fg_mask(texture(TEXTURE, UV + texel * vec2( 0,  r))));
	n = max(n, fg_mask(texture(TEXTURE, UV + texel * vec2( 0, -r))));
	n = max(n, fg_mask(texture(TEXTURE, UV + texel * vec2( r,  r))));
	n = max(n, fg_mask(texture(TEXTURE, UV + texel * vec2( r, -r))));
	n = max(n, fg_mask(texture(TEXTURE, UV + texel * vec2(-r,  r))));
	n = max(n, fg_mask(texture(TEXTURE, UV + texel * vec2(-r, -r))));

	if (fg > 0.0) {
		COLOR = tex;                 // draw original
	} else if (n > 0.0) {
		COLOR = outline_color;       // outline where BG pixel neighbors FG
	} else {
		COLOR = vec4(0.0);           // fully transparent
	}
}
"""
	_outline_material = ShaderMaterial.new()
	_outline_material.shader = _outline_shader
	_outline_material.set_shader_parameter("outline_color", outline_color)
	_outline_material.set_shader_parameter("outline_px", float(max(1, outline_px)))
	_outline_material.set_shader_parameter("key_color", Vector3(key_color.r, key_color.g, key_color.b))
	_outline_material.set_shader_parameter("key_tol", key_tol)

## Public API ------------------------------------------------------------------

## Bake a Node2D group (all child Sprite2D) into a single outlined Sprite2D.
## - group: Node2D with the fully-built tree sprites
## - anchor_world: bottom-center world pos for placement (not used for offset math here;
##                 we place at tight bounds' top-left)
## - z_index: final z for the baked sprite
## - parent_for_output: node to receive the outlined sprite
func bake_tree(group: Node2D, anchor_world: Vector2, z_index: int, parent_for_output: Node) -> Sprite2D:
	_init_shader()

	var sprites: Array[Sprite2D] = _collect_sprites(group)
	if sprites.is_empty():
		group.queue_free()
		return null

	var bounds: Rect2 = _compute_bounds(sprites)
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		group.queue_free()
		return null

	# SubViewport to bake the group
	var vp: SubViewport = SubViewport.new()
	vp.disable_3d = true
	vp.transparent_bg = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.size = Vector2i(int(ceil(bounds.size.x)) + pad_px * 2, int(ceil(bounds.size.y)) + pad_px * 2)
	add_child(vp)

	# 2D root inside the SubViewport
	var root2d: Node2D = Node2D.new()
	vp.add_child(root2d)

	# Top-left world we will bake from
	var topleft_world: Vector2 = bounds.position - Vector2(pad_px, pad_px)

	# Clone sprites into the SubViewport with local positions
	for s in sprites:
		var clone: Sprite2D = Sprite2D.new()
		clone.texture = s.texture
		clone.region_enabled = s.region_enabled
		clone.region_rect = s.region_rect
		clone.centered = false
		clone.texture_filter = s.texture_filter
		clone.flip_h = s.flip_h
		clone.flip_v = s.flip_v
		clone.position = s.global_position - topleft_world
		root2d.add_child(clone)

	# Ensure the SubViewport renders before sampling
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	# Outlined sprite with duplicated material (so parameters are per-instance)
	var out_tex: Texture2D = vp.get_texture()
	var outlined: Sprite2D = Sprite2D.new()
	outlined.texture = out_tex
	outlined.centered = false
	outlined.material = _outline_material.duplicate()
	var mat := outlined.material as ShaderMaterial
	mat.set_shader_parameter("outline_color", outline_color)
	mat.set_shader_parameter("outline_px", float(max(1, outline_px)))
	mat.set_shader_parameter("key_color", Vector3(key_color.r, key_color.g, key_color.b))
	mat.set_shader_parameter("key_tol", key_tol)

	outlined.global_position = topleft_world
	outlined.z_as_relative = false
	outlined.z_index = z_index

	if parent_for_output != null:
		parent_for_output.add_child(outlined)
	else:
		add_child(outlined)

	# Cleanup
	group.queue_free()
	vp.queue_free()
	return outlined

## Helpers ---------------------------------------------------------------------

func _collect_sprites(n: Node) -> Array[Sprite2D]:
	var arr: Array[Sprite2D] = []
	_collect_sprites_rec(n, arr)
	return arr

func _collect_sprites_rec(n: Node, out: Array[Sprite2D]) -> void:
	for c in n.get_children():
		if c is Sprite2D:
			out.append(c)
		_collect_sprites_rec(c, out)

func _compute_bounds(sprites: Array[Sprite2D]) -> Rect2:
	var first := true
	var r := Rect2()
	for s in sprites:
		var sz := Vector2.ZERO
		if s.region_enabled:
			sz = s.region_rect.size
		elif s.texture:
			sz = s.texture.get_size()
		else:
			continue
		var rr := Rect2(s.global_position, sz) # centered = false -> top-left
		if first:
			r = rr
			first = false
		else:
			r = r.merge(rr)
	return r
