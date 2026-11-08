uniform FrameInfo {
  mat4 mvp;
  vec4 light_dir;
  vec4 base_color;
  mat4 model;
  vec4 clip;
  vec4 extra;
}
frame_info;

in vec3 position;
in vec3 normal;
out vec3 v_color;
out float v_clip;
out float v_alpha;

void main() {
  vec3 n = normalize(normal);
  vec3 l = normalize(frame_info.light_dir.xyz);
  float key = max(dot(n, l), 0.0);
  float fill = max(dot(n, -l), 0.0) * 0.25;
  float lit = 0.28 + 0.62 * key + fill;
  // extra.x > 0: sin iluminación (aristas).
  if (frame_info.extra.x > 0.5) {
    lit = 1.0;
  }
  v_alpha = frame_info.base_color.a;
  v_color = frame_info.base_color.rgb * lit * v_alpha;
  // Plano de sección: positivo = se descarta.
  vec4 world = frame_info.model * vec4(position, 1.0);
  v_clip = dot(frame_info.clip.xyz, world.xyz) - frame_info.clip.w;
  vec4 p = frame_info.mvp * vec4(position, 1.0);
  // Desplazamiento en píxeles (grosor de línea) y acercamiento a la cámara (aristas).
  p.xy += frame_info.extra.zw * p.w;
  p.z -= frame_info.extra.y * p.w;
  gl_Position = p;
}
