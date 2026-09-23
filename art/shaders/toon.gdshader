// Optional hand-rolled toon shader (art agent). The StandardMaterial3D library in res://art/materials/ is
// the default; use this only when you need a crisper cel band or a coloured rim the built-in modes can't do.
// Example material: res://art/shaders/toon_example.tres
shader_type spatial;

uniform vec4 albedo : source_color = vec4(0.6, 0.42, 1.0, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white;
// Width of the soft edge between the lit and shaded band (0 = hard cel edge).
uniform float band_softness : hint_range(0.0, 0.5) = 0.06;
// Moves the terminator: negative = more of the surface lit.
uniform float band_offset : hint_range(-1.0, 1.0) = -0.1;
uniform vec4 rim_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float rim_width : hint_range(0.0, 1.0) = 0.28;
uniform float rim_strength : hint_range(0.0, 1.0) = 0.45;
uniform float specular_size : hint_range(0.0, 0.5) = 0.06;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.4;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = albedo.rgb * tex.rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	EMISSION = emission_color.rgb;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float band = smoothstep(band_offset - band_softness, band_offset + band_softness, ndl);
	float lit = band * ATTENUATION;
	DIFFUSE_LIGHT += lit * LIGHT_COLOR / PI;

	float fresnel = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = smoothstep(1.0 - rim_width, 1.0 - rim_width + 0.04, fresnel);
	DIFFUSE_LIGHT += rim * rim_strength * rim_color.rgb * max(lit, 0.3) * LIGHT_COLOR / PI;

	vec3 half_vec = normalize(VIEW + LIGHT);
	float spec = smoothstep(1.0 - specular_size, 1.0 - specular_size + 0.015, dot(NORMAL, half_vec));
	SPECULAR_LIGHT += spec * specular_strength * lit * LIGHT_COLOR / PI;
}
