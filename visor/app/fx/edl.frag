#version 460 core
#include <flutter/runtime_effect.glsl>

// Sombreado de borde (Eye-Dome Lighting): oscurece cada punto según cuánto más cerca están sus
// vecinos, lo que da relieve a una nube sin normales.
uniform vec2 uCanvas;
uniform vec2 uImage;
uniform float uStrength;
uniform float uNear;
uniform float uFar;
uniform float uRadius;
uniform sampler2D uColor;
uniform sampler2D uDepth;

out vec4 fragColor;

float depthAt(vec2 uv) {
  vec4 d = texture(uDepth, uv);
  return d.r + d.g / 255.0;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uCanvas;
  vec4 col = texture(uColor, uv);
  float t = depthAt(uv);
  if (t > 0.9985) {
    fragColor = col;
    return;
  }
  float z = uNear + t * (uFar - uNear);
  float lz = log2(z);
  float lfar = log2(uFar);
  vec2 px = vec2(uRadius) / uImage;
  float obs = 0.0;
  for (int i = 0; i < 8; i++) {
    float a = float(i) * 0.78539816;
    vec2 o = vec2(cos(a), sin(a)) * px;
    float tn = depthAt(uv + o);
    float ln = tn > 0.9985 ? lfar : log2(uNear + tn * (uFar - uNear));
    obs += max(0.0, lz - ln);
  }
  float shade = exp(-obs * uStrength * 40.0);
  fragColor = vec4(col.rgb * shade, col.a);
}
