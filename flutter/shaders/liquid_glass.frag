#version 460 core
#include <flutter/runtime_effect.glsl>

// Liquid-glass bar: edge refraction + slight chromatic dispersion + tint and
// fresnel rim lighting.
//
// Uniform layout (float indices are matched by lib/presentation/widgets/
// liquid_glass_shader.dart; uSize and uTexture are written by the engine):
//   0,1    uSize                 input texture size, filled in by the engine
//   sampler 0 uTexture           filtered input image
//   2      uCornerRadius         corner radius, device pixels
//   3      uBezelWidth           refracting bezel width, device pixels
//   4      uRefractStrength      uv-space displacement at the edge (0..0.15)
//   5      uChromaticAberration  per-channel displacement spread (0..0.02)
//   6..9   uTintColor            rgba tint, alpha carries the tint strength
//   10..13 uBarRect              bar rect x, y, w, h in engine pixel space

uniform vec2 uSize;
uniform sampler2D uTexture;
uniform float uCornerRadius;
uniform float uBezelWidth;
uniform float uRefractStrength;
uniform float uChromaticAberration;
uniform vec4 uTintColor;
uniform vec4 uBarRect;

out vec4 fragColor;

// Signed distance to a rounded rectangle plus its outward unit normal.
// p is relative to the rect center, halfSize its half extent.
// Returns (distance, normal.x, normal.y); analytic, no derivatives.
vec3 roundedRectField(vec2 p, vec2 halfSize, float radius) {
  vec2 hs = max(halfSize, vec2(0.5));
  float r = clamp(radius, 0.0, min(hs.x, hs.y));
  vec2 q = abs(p) - hs + vec2(r);
  vec2 m = max(q, vec2(0.0));
  float len = length(m);
  float dist = len + min(max(q.x, q.y), 0.0) - r;

  // Radial gradient in the corner arcs, axis aligned on the straight edges.
  vec2 g;
  if (len > 1e-5) {
    g = m / len;
  } else if (q.x > q.y) {
    g = vec2(1.0, 0.0);
  } else {
    g = vec2(0.0, 1.0);
  }
  vec2 sx = vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
  vec2 n = g * sx;
  return vec3(dist, n);
}

void main() {
  vec2 size = max(uSize, vec2(1.0));
  vec2 uv = FlutterFragCoord().xy / size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  // Geometry is derived from the (y-corrected) sampling coordinate, not from
  // the raw frag coord: on GLES the frag coord is y-flipped, and using it
  // directly would mirror the SDF and put the bezel on the wrong side.
  vec2 pos = uv * size;

  // Fall back to the full texture when the bar rect is missing or degenerate.
  vec4 rect = uBarRect;
  if (rect.z <= 0.0 || rect.w <= 0.0) {
    rect = vec4(0.0, 0.0, size.x, size.y);
  }
  vec2 halfSize = max(rect.zw * 0.5, vec2(0.5));
  vec2 center = rect.xy + halfSize;

  float radius = clamp(uCornerRadius, 0.0, min(halfSize.x, halfSize.y));
  float bezel = clamp(uBezelWidth, 1.0, min(halfSize.x, halfSize.y));

  vec3 field = roundedRectField(pos - center, halfSize, radius);
  float dist = field.x;
  vec2 normal = field.yz;
  vec2 dir = normalize(normal + vec2(1e-5, 1e-5));

  vec4 base = texture(uTexture, uv);

  // Refraction lives in the bezel band only and dies out towards the center.
  float edge = smoothstep(-bezel, 0.0, dist);
  float bend = pow(edge, 2.0);
  float strength = clamp(uRefractStrength, 0.0, 0.15);
  float ca = clamp(uChromaticAberration, 0.0, 0.02);
  vec2 offset = dir * strength * bend;

  // Three chromatic samples plus the base sample (4 total, no loops).
  vec4 rSample = texture(uTexture, clamp(uv + offset * (1.0 + ca), vec2(0.0), vec2(1.0)));
  vec4 gSample = texture(uTexture, clamp(uv + offset, vec2(0.0), vec2(1.0)));
  vec4 bSample = texture(uTexture, clamp(uv + offset * (1.0 - ca), vec2(0.0), vec2(1.0)));
  vec3 refracted = vec3(rSample.r, gSample.g, bSample.b);

  vec3 tinted = mix(refracted, uTintColor.rgb, clamp(uTintColor.a, 0.0, 1.0));

  // Extreme edge: fresnel rim, brighter where the surface faces up.
  float upFacing = clamp(normal.y * 0.5 + 0.5, 0.0, 1.0);
  float rim = 1.0 - smoothstep(0.0, 1.5, abs(dist));
  float rimLight = mix(-0.20, 0.55, upFacing) * rim;

  // Soft specular band just inside the bezel.
  float band = 1.0 - smoothstep(0.0, bezel * 0.6, abs(dist + bezel * 0.55));
  float bandLight = band * 0.10 * (0.35 + 0.65 * upFacing);

  vec3 glass = clamp(tinted + vec3(rimLight + bandLight), 0.0, 1.0);
  vec4 color = vec4(glass, base.a);

  // Anything outside the bar keeps the untouched input, so the filter is safe
  // to apply to a full-screen (or slightly over-sized) input.
  float inside = 1.0 - smoothstep(-0.5, 0.75, dist);
  fragColor = mix(base, color, inside);
}
