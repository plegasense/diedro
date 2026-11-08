uniform FrameInfo {
  mat4 mvp;
  vec4 tint;
  vec4 offset;
  mat4 model;
  vec4 clip;
}
frame_info;

in vec3 position;
in vec3 color;
out vec3 v_color;
out float v_clip;
out float v_alpha;

void main() {
  v_alpha = 1.0;
  vec4 world = frame_info.model * vec4(position, 1.0);
  v_clip = dot(frame_info.clip.xyz, world.xyz) - frame_info.clip.w;
  vec4 p = frame_info.mvp * vec4(position, 1.0);
  if (frame_info.tint.w < 0.0) {
    // Pasada de profundidad (sombreado de borde): la distancia al ojo normalizada entre el plano
    // cercano (tint.y) y el lejano (tint.z), repartida en dos canales de 8 bits.
    float t = clamp((p.w - frame_info.tint.y) / (frame_info.tint.z - frame_info.tint.y), 0.0, 1.0);
    float s = t * 255.0;
    float hi = floor(s);
    v_color = vec3(hi / 255.0, s - hi, 0.0);
  } else {
    v_color = color * frame_info.tint.rgb;
  }
  p.xy += frame_info.offset.xy * p.w;
  // Acerca un poco las líneas a la cámara para que no se pierdan en la superficie.
  p.z -= frame_info.offset.w * p.w;
  gl_Position = p;
  gl_PointSize = frame_info.offset.z;
}
