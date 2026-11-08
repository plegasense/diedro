uniform FrameInfo {
  mat4 mvp;
  vec4 light_dir;
  vec4 base_color;
  mat4 model;
  vec4 clip;
  vec4 flags;
  vec4 uvt;
  vec4 uvr;
}
frame_info;

in vec3 position;
in vec3 normal;
in vec2 uv;
in vec4 color;
out float v_lit;
out vec2 v_uv;
out vec4 v_color;
out float v_clip;
out vec3 v_pos;
out vec3 v_nrm;

void main() {
  vec3 n = normalize(normal);
  vec3 l = normalize(frame_info.light_dir.xyz);
  float key = max(dot(n, l), 0.0);
  float fill = max(dot(n, -l), 0.0) * 0.25;
  float lit = 0.28 + 0.62 * key + fill;
  // flags.x > 0: sin iluminación (material «unlit» o tapa de sección).
  if (frame_info.flags.x > 0.5) {
    lit = 1.0;
  }
  v_lit = lit;
  vec2 t = uv * frame_info.uvt.zw;
  t = vec2(
      frame_info.uvr.y * t.x - frame_info.uvr.x * t.y,
      frame_info.uvr.x * t.x + frame_info.uvr.y * t.y);
  v_uv = t + frame_info.uvt.xy;
  v_color = color;
  v_pos = position;
  v_nrm = n;
  vec4 world = frame_info.model * vec4(position, 1.0);
  v_clip = dot(frame_info.clip.xyz, world.xyz) - frame_info.clip.w;
  gl_Position = frame_info.mvp * vec4(position, 1.0);
}
