shader_type canvas_item;

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float alpha_threshold : hint_range(0.0, 1.0) = 0.1;
uniform bool diagonals_enabled = true;

void fragment() {
    vec4 base = texture(TEXTURE, UV);
    float a = base.a;

    vec2 px = TEXTURE_PIXEL_SIZE;

    // Neighbor taps (orthogonal)
    float n = texture(TEXTURE, UV + vec2( 0.0, -px.y)).a;
    float s = texture(TEXTURE, UV + vec2( 0.0,  px.y)).a;
    float w = texture(TEXTURE, UV + vec2(-px.x,  0.0)).a;
    float e = texture(TEXTURE, UV + vec2( px.x,  0.0)).a;

    bool touch = (n > alpha_threshold) || (s > alpha_threshold) ||
                 (w > alpha_threshold) || (e > alpha_threshold);

    if (diagonals_enabled) {
        float nw = texture(TEXTURE, UV + vec2(-px.x, -px.y)).a;
        float ne = texture(TEXTURE, UV + vec2( px.x, -px.y)).a;
        float sw = texture(TEXTURE, UV + vec2(-px.x,  px.y)).a;
        float se = texture(TEXTURE, UV + vec2( px.x,  px.y)).a;
        touch = touch || (nw > alpha_threshold) || (ne > alpha_threshold) ||
                        (sw > alpha_threshold) || (se > alpha_threshold);
    }

    // Draw outline only where base is transparent AND a neighbor is solid.
    bool is_outline = (a <= alpha_threshold) && touch;
    COLOR = is_outline ? outline_color : vec4(0.0);
}
