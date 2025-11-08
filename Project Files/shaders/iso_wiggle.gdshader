shader_type canvas_item;

uniform float amplitude_px : hint_range(0.0, 8.0, 0.01) = 0.8;
uniform float frequency : hint_range(0.1, 20.0, 0.1) = 6.0;
uniform float speed : hint_range(0.0, 8.0, 0.01) = 1.0;
uniform vec2 axis = vec2(1.0, 0.0);
uniform float noise_mix : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float alpha_soften : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform vec2 world_phase_scale = vec2(0.015, 0.015);
uniform float base_phase = 0.0;
uniform vec2 leaf_world_pos = vec2(0.0, 0.0);
uniform vec2 wind_noise_scale = vec2(0.01, 0.01);
uniform vec2 wind_noise_offset = vec2(0.0, 0.0);
uniform vec2 wind_scroll_dir = vec2(0.6, 0.2);
uniform float wind_scroll_speed = 0.15;
uniform float wind_strength = 0.45;
uniform float wind_min_strength = 0.2;
uniform float wind_axis_mix = 0.85;

varying float v_leaf_phase;

vec2 _safe_normalize(vec2 v) {
	float len = length(v);
	return (len > 0.0001) ? (v / len) : vec2(0.0);
}

float _hash11(float n) {
	return fract(sin(n) * 43758.5453);
}

float _hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 _grad2(vec2 p) {
	float h = _hash21(p) * TAU;
	return vec2(cos(h), sin(h));
}

float _phase_from_world(vec2 world_pos) {
	float n = dot(world_pos * world_phase_scale, vec2(12.9898, 78.233)) + base_phase;
	return _hash11(n) * TAU;
}

float _wave(float coord, float phase) {
	float base = sin(coord * frequency + TIME * speed + phase);
	float alt = sin(coord * (frequency * 0.62) + TIME * speed * 1.37 + phase * 1.3);
	return mix(base, alt, clamp(noise_mix, 0.0, 1.0));
}

float _perlin(vec2 p) {
	vec2 cell = floor(p);
	vec2 local = fract(p);
	vec2 u = local * local * (3.0 - 2.0 * local);

	float a = dot(_grad2(cell + vec2(0.0, 0.0)), local - vec2(0.0, 0.0));
	float b = dot(_grad2(cell + vec2(1.0, 0.0)), local - vec2(1.0, 0.0));
	float c = dot(_grad2(cell + vec2(0.0, 1.0)), local - vec2(0.0, 1.0));
	float d = dot(_grad2(cell + vec2(1.0, 1.0)), local - vec2(1.0, 1.0));

	float mix_x1 = mix(a, b, u.x);
	float mix_x2 = mix(c, d, u.x);
	return mix(mix_x1, mix_x2, u.y);
}

vec2 _wind_vector(vec2 world_pos, vec2 base_dir) {
	vec2 sample = world_pos * wind_noise_scale + wind_noise_offset + wind_scroll_dir * (TIME * wind_scroll_speed);
	float nx = _perlin(sample);
	float ny = _perlin(sample + vec2(37.2, 17.9));
	vec2 noise_dir = _safe_normalize(vec2(nx, ny));
	float mix_amount = clamp(wind_axis_mix, 0.0, 1.0);
	vec2 final_dir;
	if (mix_amount <= 0.0) {
		final_dir = (base_dir == vec2(0.0)) ? noise_dir : base_dir;
	} else if (mix_amount >= 1.0) {
		final_dir = (noise_dir == vec2(0.0)) ? base_dir : noise_dir;
	} else {
		final_dir = _safe_normalize(mix(base_dir, noise_dir, mix_amount));
	}
	float magnitude = amplitude_px * (wind_min_strength + abs(nx) * wind_strength);
	return final_dir * magnitude;
}

void vertex() {
	vec2 dir = _safe_normalize(axis);
	vec2 world_pos = leaf_world_pos;
	float phase = _phase_from_world(world_pos);
	v_leaf_phase = phase;
	if (amplitude_px != 0.0) {
		vec2 wind_vec = _wind_vector(world_pos, dir);
		float w = _wave(UV.y, phase);
		VERTEX.xy += wind_vec * w;
	}
}

void fragment() {
	vec4 col = texture(TEXTURE, UV) * COLOR;
	if (alpha_soften > 0.0) {
		float fade = clamp(1.0 - alpha_soften * abs(_wave(UV.y, v_leaf_phase)), 0.0, 1.0);
		col.a *= fade;
	}
	COLOR = col;
}
