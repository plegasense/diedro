uniform sampler2D base_tex;
uniform sampler2D mr_tex;
uniform sampler2D normal_tex;
uniform sampler2D occ_tex;
uniform sampler2D emis_tex;

uniform FragInfo {
  vec4 base_color;
  vec4 flags;
  vec4 emissive;
  vec4 eye;
  vec4 up_m;
  vec4 light_dir;
  vec4 pbr;
}
fi;

in float v_lit;
in vec2 v_uv;
in vec4 v_color;
in float v_clip;
in vec3 v_pos;
in vec3 v_nrm;
out vec4 frag_color;

const float PI = 3.14159265;

vec3 toLinear(vec3 c) {
  return pow(max(c, vec3(0.0)), vec3(2.2));
}

void main() {
  if (v_clip > 0.0) {
    discard;
  }
  vec4 c = fi.base_color * texture(base_tex, v_uv);
  // flags.y > 0.5: multiplicar por el color de vértice.
  if (fi.flags.y > 0.5) {
    c *= v_color;
  }
  // flags.z >= 0: modo «mask» con ese umbral.
  if (fi.flags.z >= 0.0 && c.a < fi.flags.z) {
    discard;
  }
  float a = c.a;
  // flags.w > 0.5: opaco (se ignora el alfa del material y de la textura).
  if (fi.flags.w > 0.5 || fi.flags.z >= 0.0) {
    a = 1.0;
  }

  // fi.up_m.w > 0.5: material PBR (glTF); si no, iluminación sencilla.
  if (fi.up_m.w < 0.5 || fi.flags.x > 0.5) {
    frag_color = vec4((c.rgb * v_lit + fi.emissive.rgb) * a, a);
    return;
  }

  vec3 N = normalize(v_nrm);
  vec3 V = normalize(fi.eye.xyz - v_pos);
  // pbr.z: escala del mapa de normales (0 = sin mapa)
  if (fi.pbr.z > 0.0) {
    vec3 dp1 = dFdx(v_pos);
    vec3 dp2 = dFdy(v_pos);
    vec2 duv1 = dFdx(v_uv);
    vec2 duv2 = dFdy(v_uv);
    vec3 dp2perp = cross(dp2, N);
    vec3 dp1perp = cross(N, dp1);
    vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;
    float invmax = inversesqrt(max(max(dot(T, T), dot(B, B)), 1e-12));
    vec3 nt = texture(normal_tex, v_uv).xyz * 2.0 - 1.0;
    nt.xy *= fi.pbr.z;
    N = normalize(mat3(T * invmax, B * invmax, N) * nt);
  }
  // iluminación por las dos caras
  if (dot(N, V) < 0.0) {
    N = -N;
  }

  vec3 albedo = toLinear(c.rgb);
  vec4 mrt = texture(mr_tex, v_uv);
  float rough = clamp(fi.pbr.y * mrt.g, 0.045, 1.0);
  float metal = clamp(fi.pbr.x * mrt.b, 0.0, 1.0);
  float ao = 1.0 + fi.pbr.w * (texture(occ_tex, v_uv).r - 1.0);
  vec3 emis = toLinear(texture(emis_tex, v_uv).rgb) * toLinear(fi.emissive.rgb);

  vec3 F0 = mix(vec3(0.04), albedo, metal);
  vec3 L = normalize(fi.light_dir.xyz);
  vec3 H = normalize(L + V);
  float NL = max(dot(N, L), 0.0);
  float NV = max(dot(N, V), 1e-3);
  float NH = max(dot(N, H), 0.0);
  float VH = max(dot(V, H), 0.0);
  float al = rough * rough;
  float a2 = al * al;
  float dd = NH * NH * (a2 - 1.0) + 1.0;
  float D = a2 / (PI * dd * dd);
  float k = (rough + 1.0) * (rough + 1.0) / 8.0;
  float G = (NL / (NL * (1.0 - k) + k)) * (NV / (NV * (1.0 - k) + k));
  vec3 F = F0 + (vec3(1.0) - F0) * pow(1.0 - VH, 5.0);
  vec3 spec = D * G * F / max(4.0 * NL * NV, 1e-3);
  vec3 diff = (vec3(1.0) - F) * (1.0 - metal) * albedo / PI;
  vec3 direct = (diff + spec) * NL * 3.1;

  // luz de relleno desde el lado opuesto, solo difusa
  float NLf = max(dot(N, -L), 0.0);
  direct += (1.0 - metal) * albedo / PI * NLf * 0.8;

  // entorno: hemisferio (cielo claro, suelo oscuro) para difuso y reflejo
  vec3 sky = vec3(0.62, 0.68, 0.78);
  vec3 ground = vec3(0.16, 0.15, 0.14);
  float hu = dot(N, fi.up_m.xyz) * 0.5 + 0.5;
  vec3 irr = mix(ground, sky, hu);
  vec3 ambient = albedo * (1.0 - metal) * irr * ao * 0.9;
  vec3 R = reflect(-V, N);
  float hr = dot(R, fi.up_m.xyz) * 0.5 + 0.5;
  vec3 env = mix(ground, sky * 1.4, smoothstep(0.0, 1.0, hr));
  float gloss = 1.0 - rough;
  vec3 Fenv = F0 + (max(vec3(gloss), F0) - F0) * pow(1.0 - NV, 5.0);
  vec3 specAmb = env * Fenv * ao * (0.25 + 0.75 * gloss * gloss);

  vec3 col = direct + ambient + specAmb + emis;
  // curva suave de tonos y de vuelta a sRGB
  col = vec3(1.0) - exp(-col * 1.35);
  col = pow(col, vec3(1.0 / 2.2));
  frag_color = vec4(col * a, a);
}
