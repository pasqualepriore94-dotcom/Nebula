#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Strutture condivise (layout identico a MathTypes.swift)
// ---------------------------------------------------------------------------

struct Vertex { float4 position; float4 normal; };
struct MeshInstance { float4x4 model; float4 color; float4 emissive; };
struct Sprite { float4 posSize; float4 color; float4 dir; };
struct Particle { float4 posLife; float4 velMax; float4 color; };
struct Frame {
    float4x4 viewProj;
    float4x4 view;
    float4x4 proj;
    float4 cameraPos;
    float4 lightDir;
    float4 params;   // x tempo, y scorrimento, z aspect
    float4 post;     // x flash, y aberrazione, z esposizione, w seme
};

// ---------------------------------------------------------------------------
// Triangolo a schermo intero
// ---------------------------------------------------------------------------

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// ---------------------------------------------------------------------------
// Rumore procedurale
// ---------------------------------------------------------------------------

inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline float noise2(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 6; i++) {
        v += amp * noise2(p);
        p = p * 2.02 + float2(1.7, 9.2);
        amp *= 0.5;
    }
    return v;
}

inline float3 starLayer(float2 p, float scale, float t, float density, float bright) {
    float2 g = p * scale;
    float2 id = floor(g);
    float2 f = fract(g) - 0.5;
    float h = hash21(id);
    if (h > density) return float3(0.0);
    float2 offs = float2(hash21(id + 3.1), hash21(id + 7.7)) - 0.5;
    float d = length(f - offs * 0.7);
    float tw = 0.65 + 0.35 * sin(t * (2.0 + h * 6.0) + h * 40.0);
    float3 tint = mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.85, 0.7), hash21(id + 1.9));
    float k = h / density;
    return tint * exp(-d * d * 220.0) * tw * bright * (0.6 + 2.4 * k * k);
}

// ---------------------------------------------------------------------------
// Sfondo: nebulosa con domain warping + stelle in parallasse
// ---------------------------------------------------------------------------

fragment float4 backgroundFragment(FSOut in [[stage_in]], constant Frame& f [[buffer(0)]]) {
    float t = f.params.x;
    float scroll = f.params.y;
    float aspect = f.params.z;
    float2 p = float2((in.uv.x - 0.5) * aspect, 0.5 - in.uv.y);

    float3 col = mix(float3(0.02, 0.012, 0.05), float3(0.004, 0.003, 0.015), in.uv.y);

    float2 q = p * 1.6 + float2(0.0, scroll * 0.03);
    float2 w = float2(fbm(q + float2(0.0, t * 0.02)), fbm(q + float2(5.2, 1.3)));
    float n = fbm(q + 2.5 * w);
    float3 neb = mix(float3(0.35, 0.05, 0.45), float3(0.04, 0.32, 0.55), saturate(w.x * 1.4));
    neb = mix(neb, float3(0.9, 0.3, 0.2), saturate(w.y * w.y * 1.5));
    col += neb * pow(n, 3.0) * 1.8;

    col += starLayer(p + float2(0.0, scroll * 0.015), 22.0, t, 0.22, 1.6);
    col += starLayer(p + float2(0.0, scroll * 0.04), 40.0, t, 0.28, 1.0);
    col += starLayer(p + float2(0.0, scroll * 0.09), 75.0, t, 0.32, 0.6);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------------------
// Mesh 3D illuminate (Blinn-Phong + rim + emissivo)
// ---------------------------------------------------------------------------

struct MeshOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float4 color;
    float4 emissive;
};

vertex MeshOut meshVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          const device Vertex* verts [[buffer(0)]],
                          const device MeshInstance* inst [[buffer(1)]],
                          constant Frame& f [[buffer(2)]]) {
    MeshInstance I = inst[iid];
    Vertex v = verts[vid];
    float4 wp = I.model * float4(v.position.xyz, 1.0);
    MeshOut o;
    o.position = f.viewProj * wp;
    o.worldPos = wp.xyz;
    o.normal = (I.model * float4(v.normal.xyz, 0.0)).xyz;
    o.color = I.color;
    o.emissive = I.emissive;
    return o;
}

fragment float4 meshFragment(MeshOut in [[stage_in]], constant Frame& f [[buffer(0)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(f.cameraPos.xyz - in.worldPos);
    if (dot(N, V) < 0.0) N = -N;
    float3 L = normalize(f.lightDir.xyz);
    float3 H = normalize(L + V);

    float diff = max(dot(N, L), 0.0);
    float spec = pow(max(dot(N, H), 0.0), 64.0);
    float rim = pow(1.0 - saturate(dot(N, V)), 3.0);
    float fill = max(dot(N, normalize(float3(-0.6, -0.4, 0.5))), 0.0);

    float3 sky = mix(float3(0.05, 0.03, 0.12), float3(0.12, 0.18, 0.35), N.y * 0.5 + 0.5);
    float3 lightCol = float3(1.0, 0.92, 0.85) * 2.2;
    float3 base = in.color.rgb;

    float3 c = base * (sky + diff * lightCol + fill * float3(0.4, 0.2, 0.8));
    c += spec * lightCol * in.color.a;
    c += rim * in.emissive.rgb * 1.6;
    c += in.emissive.rgb * in.emissive.a;
    return float4(c, 1.0);
}

// ---------------------------------------------------------------------------
// Sprite e particelle (billboard allungati nella direzione del moto)
// ---------------------------------------------------------------------------

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float3 color;
    float shape [[flat]];
};

constant float2 kCorners[6] = {
    float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),
    float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0)
};

inline SpriteOut billboard(float3 pos, float size, float3 dirWorld, float stretch,
                           float3 color, float shape, uint vid, constant Frame& f) {
    float4 vp = f.view * float4(pos, 1.0);
    float2 corner = kCorners[vid % 6];
    float3 dv = (f.view * float4(dirWorld, 0.0)).xyz;
    float2 axis = float2(0.0, 1.0);
    float dl = length(dv.xy);
    if (dl > 1e-4) axis = dv.xy / dl;
    float2 perp = float2(-axis.y, axis.x);
    vp.xy += perp * (corner.x * size) + axis * (corner.y * size * (1.0 + stretch));
    SpriteOut o;
    o.position = f.proj * vp;
    o.uv = corner;
    o.color = color;
    o.shape = shape;
    return o;
}

vertex SpriteOut spriteVertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              const device Sprite* sprites [[buffer(0)]],
                              constant Frame& f [[buffer(1)]]) {
    Sprite s = sprites[iid];
    return billboard(s.posSize.xyz, s.posSize.w, s.dir.xyz, s.dir.w, s.color.rgb, s.color.w, vid, f);
}

vertex SpriteOut particleVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device Particle* particles [[buffer(0)]],
                                constant Frame& f [[buffer(1)]]) {
    Particle p = particles[iid];
    float life = p.posLife.w;
    if (life <= 0.0) {
        SpriteOut o;
        o.position = float4(2.0, 2.0, 2.0, 1.0);
        o.uv = float2(0.0);
        o.color = float3(0.0);
        o.shape = 0.0;
        return o;
    }
    float t = saturate(life / max(p.velMax.w, 1e-3));
    float size = p.color.w * (0.3 + 0.7 * t);
    float3 col = p.color.rgb * t * (0.6 + 0.8 * t);
    float stretch = min(length(p.velMax.xyz) * 0.06, 3.0);
    return billboard(p.posLife.xyz, size, p.velMax.xyz, stretch, col, 0.0, vid, f);
}

fragment float4 spriteFragment(SpriteOut in [[stage_in]]) {
    float d2 = dot(in.uv, in.uv);
    float a;
    if (in.shape < 0.5) {
        a = exp(-d2 * 4.0) + exp(-d2 * 30.0) * 1.5;   // alone + nucleo caldo
    } else {
        float d = sqrt(d2);
        float r = (d - 0.82) * 9.0;
        a = exp(-r * r);                                // anello
    }
    a *= saturate(1.0 - d2);
    return float4(in.color * a, 1.0);
}

// ---------------------------------------------------------------------------
// Simulazione particelle (compute)
// ---------------------------------------------------------------------------

kernel void particleSpawn(device Particle* particles [[buffer(0)]],
                          const device Particle* spawns [[buffer(1)]],
                          constant uint4& info [[buffer(2)]],
                          uint id [[thread_position_in_grid]]) {
    if (id >= info.y) return;
    particles[(info.x + id) % info.z] = spawns[id];
}

kernel void particleUpdate(device Particle* particles [[buffer(0)]],
                           constant float4& sim [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    if (id >= uint(sim.w)) return;
    Particle p = particles[id];
    if (p.posLife.w <= 0.0) return;
    float dt = sim.x;
    p.posLife.w -= dt;
    p.posLife.xyz += p.velMax.xyz * dt;
    p.velMax.xyz *= exp(-sim.y * dt);
    p.posLife.y -= sim.z * dt;   // scorrimento verso il basso
    particles[id] = p;
}

// ---------------------------------------------------------------------------
// Bloom
// ---------------------------------------------------------------------------

kernel void bloomBright(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float4& params [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float3 c = src.sample(s, uv).rgb;
    float br = max(c.r, max(c.g, c.b));
    float knee = params.y;
    float soft = clamp(br - params.x + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float contrib = max(soft, br - params.x) / max(br, 1e-4);
    dst.write(float4(min(c * contrib, float3(64.0)), 1.0), gid);
}

kernel void bloomDown(texture2d<float, access::sample> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(float4(src.sample(s, uv).rgb, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Composizione finale: bloom, aberrazione cromatica, ACES, vignetta, grana
// ---------------------------------------------------------------------------

fragment float4 compositeFragment(FSOut in [[stage_in]],
                                  texture2d<float> scene [[texture(0)]],
                                  texture2d<float> bloom1 [[texture(1)]],
                                  texture2d<float> bloom2 [[texture(2)]],
                                  constant Frame& f [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 c = uv - 0.5;
    float ab = 0.004 + f.post.y * 0.03;

    float3 hdr;
    hdr.r = scene.sample(s, uv + c * ab).r;
    hdr.g = scene.sample(s, uv).g;
    hdr.b = scene.sample(s, uv - c * ab).b;
    hdr += bloom1.sample(s, uv).rgb * 0.7 + bloom2.sample(s, uv).rgb * 1.1;

    float3 hurt = hdr * float3(1.6, 0.35, 0.35) + float3(0.12, 0.0, 0.0);
    hdr = mix(hdr, hurt, f.post.x * 0.6);
    hdr *= f.post.z;

    float3 x = hdr;
    float3 mapped = saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
    mapped *= 1.0 - dot(c, c) * 0.9;

    float grain = fract(sin(dot(uv * 1000.0 + f.post.w, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    mapped += grain * 0.025;
    mapped = pow(saturate(mapped), float3(1.0 / 2.2));
    return float4(mapped, 1.0);
}
