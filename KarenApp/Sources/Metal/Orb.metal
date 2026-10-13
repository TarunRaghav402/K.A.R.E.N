#include <metal_stdlib>
using namespace metal;

// ─── Uniforms ────────────────────────────────────────────────────────────────

struct OrbUniforms {
    float4x4 modelMatrix;
    float4x4 viewProjection;
    float    time;
    float    audioLevel;    // 0–1
    int      orbState;      // 0=idle 1=listening 2=processing 3=speaking 4=permission 5=error
    float    zoom;
    float    yaw;
    float    pitch;
    float    lodLevel;      // 0=normal, 1=zoomed in (dense neural)
    float    reduceMotion;  // 1 = reduce motion accessibility
    float2   pad;
};

// ─── State constants ──────────────────────────────────────────────────────────
constant int STATE_IDLE       = 0;
constant int STATE_LISTENING  = 1;
constant int STATE_PROCESSING = 2;
constant int STATE_SPEAKING   = 3;
constant int STATE_PERMISSION = 4;
constant int STATE_ERROR      = 5;

float3 themeAccent(int state) {
    if (state == STATE_LISTENING) return float3(0.12, 0.92, 0.48);
    if (state == STATE_SPEAKING || state == STATE_ERROR) return float3(1.0, 0.20, 0.27);
    if (state == STATE_PERMISSION) return float3(1.0, 0.64, 0.20);
    return float3(0.22, 0.52, 1.0);
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

// 3D rotation matrices
float3x3 rotX(float a) {
    return float3x3(float3(1,0,0), float3(0,cos(a),-sin(a)), float3(0,sin(a),cos(a)));
}
float3x3 rotY(float a) {
    return float3x3(float3(cos(a),0,sin(a)), float3(0,1,0), float3(-sin(a),0,cos(a)));
}

// Smooth noise helpers
float hash(float3 p) {
    p = fract(p * float3(443.897, 441.423, 437.195));
    p += dot(p, p.yzx + 19.19);
    return fract((p.x + p.y) * p.z);
}
float noise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    f = f*f*(3.0-2.0*f);
    return mix(mix(mix(hash(i),               hash(i+float3(1,0,0)),f.x),
                   mix(hash(i+float3(0,1,0)), hash(i+float3(1,1,0)),f.x),f.y),
               mix(mix(hash(i+float3(0,0,1)), hash(i+float3(1,0,1)),f.x),
                   mix(hash(i+float3(0,1,1)), hash(i+float3(1,1,1)),f.x),f.y),f.z);
}
float fbm(float3 p, int octaves) {
    float v=0,a=0.5;
    for(int i=0;i<octaves;i++){ v+=a*noise3(p); p*=2.0; a*=0.5; }
    return v;
}

// ─── Star field ───────────────────────────────────────────────────────────────
// Vertex: draws full-screen quad; fragment generates procedural stars.

struct StarVertex { float4 pos [[position]]; float2 uv; };

vertex StarVertex star_vert(uint vid [[vertex_id]]) {
    float2 positions[4] = { {-1,-1},{1,-1},{-1,1},{1,1} };
    float2 uvs[4]       = { {0,1},  {1,1}, {0,0}, {1,0} };
    StarVertex out;
    out.pos = float4(positions[vid],0,1);
    out.uv  = uvs[vid];
    return out;
}

fragment float4 star_frag(StarVertex in [[stage_in]],
                           constant OrbUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    // State-tinted deep space with a distant, soft point of light.
    float3 accent = themeAccent(u.orbState);
    float3 bg = mix(float3(0.004, 0.008, 0.020) + accent * 0.010,
                    float3(0.008, 0.014, 0.035) + accent * 0.025, uv.y * 0.4);
    float2 sourceDelta = uv - float2(0.79, 0.20);
    float sourceGlow = exp(-dot(sourceDelta, sourceDelta) * 15.0) * 0.10;
    bg += accent * sourceGlow;

    // Sparse stars — hash grid
    float3 col = bg;
    float2 cell = floor(uv * 180.0);
    float2 off  = fract(uv * 180.0);
    float h = hash(float3(cell, 1.7));
    if (h > 0.993) {
        float twinkle = 0.7 + 0.3 * sin(u.time * (2.0 + h * 3.0) + h * 6.28);
        float r = length(off - 0.5);
        float star = smoothstep(0.25, 0.0, r) * twinkle;
        col += float3(star * mix(0.14, 0.28, h)) * mix(float3(0.85, 0.90, 1.0), accent, 0.38);
    }

    // Very faint nebula
    float neb = fbm(float3(uv * 1.8, u.time * 0.02), 3) * 0.012;
    col += float3(0.04, 0.08, 0.22) * neb;

    return float4(col, 1.0);
}

// ─── Orb filament shell ───────────────────────────────────────────────────────
// Instanced points on a sphere; each instance = one filament point.

struct FilamentIn {
    uint instanceId [[instance_id]];
};
struct FilamentOut {
    float4 pos [[position]];
    float4 color;
    float  psize [[point_size]];
    float  alpha;
};

vertex FilamentOut filament_vert(
    FilamentIn in [[stage_in]],
    constant OrbUniforms& u [[buffer(0)]])
{
    // Fibonacci sphere distribution
    uint N = 8192;
    float i = float(in.instanceId);
    float phi = acos(1.0 - 2.0*(i+0.5)/float(N));
    float theta = 3.141592653589 * (1.0 + sqrt(5.0)) * i;

    // Shell radius varies by shell layer (3 layers)
    uint shell = in.instanceId % 3;
    float baseR = 0.38 + float(shell) * 0.14;

    // Time-based breathing (state-dependent)
    float speed = (u.reduceMotion > 0.5) ? 0.2 : 1.0;
    float breathe = sin(u.time * 0.8 * speed) * 0.018;
    float noiseOffset = fbm(float3(sin(theta)*cos(phi), sin(phi), cos(theta)) + u.time * 0.12 * speed, 2) * 0.06;

    float radius = baseR + breathe + noiseOffset;

    // State modulations
    if (u.orbState == STATE_LISTENING) {
        // Rings tighten toward equator; pulse with audio
        float equatorBias = 1.0 - abs(cos(phi)) * 0.4;
        radius *= equatorBias;
        radius += u.audioLevel * 0.06 * sin(u.time * 12.0 * speed + i * 0.01);
    } else if (u.orbState == STATE_PROCESSING) {
        // Filaments flow inward to core
        float inward = (sin(u.time * 2.5 * speed + i * 0.03) * 0.5 + 0.5);
        radius *= mix(1.0, 0.55, inward);
    } else if (u.orbState == STATE_SPEAKING) {
        // Waveform ripples across shell
        float wave = sin(phi * 6.0 + u.time * 4.0 * speed) * 0.035 * (1.0 + u.audioLevel);
        radius += wave;
    } else if (u.orbState == STATE_PERMISSION) {
        // Locked rings — barely move
        radius = baseR + sin(u.time * 0.3) * 0.005;
    } else if (u.orbState == STATE_ERROR) {
        // Flicker / broken pattern
        float flicker = step(0.5, fract(u.time * 8.0 + i * 0.17));
        radius = baseR * (0.75 + flicker * 0.35);
    }

    // LOD: zoom in → denser, branching look
    if (u.lodLevel > 0.5) {
        radius *= 0.6;
        float branch = fbm(float3(phi, theta, u.time * 0.5 * speed), 4) * 0.12;
        radius += branch;
    }

    float3 localPos = float3(sin(phi)*cos(theta), cos(phi), sin(phi)*sin(theta)) * radius;

    // Apply user yaw/pitch rotation
    float3 rotated = rotX(u.pitch) * (rotY(u.yaw) * localPos);

    float4 worldPos = float4(rotated * u.zoom, 1.0);
    FilamentOut out;
    out.pos = u.viewProjection * worldPos;

    // Color: deep blue filament gradient
    float3 midColor   = themeAccent(u.orbState);
    float3 coreColor  = mix(float3(0.95, 0.97, 1.0), midColor, 0.20);
    float3 outerColor = midColor * float3(0.20, 0.27, 0.42);

    float t = clamp(length(localPos) / 0.65, 0.0, 1.0);
    float3 baseColor = mix(coreColor, midColor, smoothstep(0.0, 0.4, t));
    baseColor = mix(baseColor, outerColor, smoothstep(0.4, 1.0, t));

    // Error state: desaturate + flicker red tinge
    if (u.orbState == STATE_ERROR) {
        float lum = dot(baseColor, float3(0.299, 0.587, 0.114));
        baseColor = mix(baseColor, float3(lum), 0.6) + float3(0.15, 0.0, 0.0);
    }

    float alphaBase = mix(0.85, 0.25, t);
    out.alpha = alphaBase;
    out.color = float4(baseColor, alphaBase);
    out.psize = mix(3.5, 1.2, t) * u.zoom;
    return out;
}

fragment float4 filament_frag(FilamentOut in [[stage_in]]) {
    // Soft circle for each point
    float2 coord = in[[point_coord]] * 2.0 - 1.0;
    float r = dot(coord, coord);
    if (r > 1.0) discard_fragment();
    float a = (1.0 - r) * in.alpha;
    return float4(in.color.rgb, a);
}

// ─── Orbiting rings ───────────────────────────────────────────────────────────

struct RingVertex {
    float2 uv [[attribute(0)]];
};
struct RingOut {
    float4 pos [[position]];
    float2 uv;
    float  ring;
    float  alpha;
};

vertex RingOut ring_vert(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant OrbUniforms& u [[buffer(0)]])
{
    uint SEGS = 256;
    float angle = float(vid) / float(SEGS) * 2.0 * 3.14159265;

    float speed = (u.reduceMotion > 0.5) ? 0.1 : 1.0;

    // 3 rings with different tilt angles
    float tilts[3]  = { 0.42, -0.65, 0.25 };
    float radii[3]  = { 0.55,  0.48,  0.62 };
    float speeds[3] = { 0.25,  -0.18, 0.31 };

    float tilt  = tilts[iid];
    float R     = radii[iid];
    float spd   = speeds[iid];

    float rotAngle = u.time * spd * speed;

    // State modifications
    if (u.orbState == STATE_LISTENING) {
        R *= 0.85 + u.audioLevel * 0.08;  // tighten toward core
    } else if (u.orbState == STATE_PROCESSING) {
        spd *= 3.0;
        rotAngle = u.time * spd * speed;
    } else if (u.orbState == STATE_PERMISSION) {
        // Lock — barely rotate
        rotAngle = 0.0;
    } else if (u.orbState == STATE_ERROR) {
        // Flicker gap
        if (fract(u.time * 6.0 + float(iid) * 0.4) > 0.75) {
            R = 0.0; // hide segment → broken ring effect
        }
    }

    float3 p = float3(R * cos(angle), 0, R * sin(angle));
    // Tilt ring
    p = rotX(tilt) * p;
    // Spin
    p = rotY(rotAngle) * p;
    // User rotation
    p = rotX(u.pitch) * (rotY(u.yaw) * p);

    RingOut out;
    out.pos   = u.viewProjection * float4(p * u.zoom, 1.0);
    out.uv    = float2(angle / (2.0*3.14159), 0.5);
    out.ring  = float(iid);
    out.alpha = (u.orbState == STATE_PERMISSION) ? 0.9 : 0.45;
    return out;
}

fragment float4 ring_frag(RingOut in [[stage_in]],
                           constant OrbUniforms& u [[buffer(0)]]) {
    float3 color = themeAccent(u.orbState);
    return float4(color, in.alpha);
}

// ─── Core glow ────────────────────────────────────────────────────────────────

struct CoreOut { float4 pos [[position]]; float2 uv; };

vertex CoreOut core_vert(uint vid [[vertex_id]],
                          constant OrbUniforms& u [[buffer(0)]]) {
    float2 positions[4] = { {-1,-1},{1,-1},{-1,1},{1,1} };
    float2 uvs[4]       = { {0,0},  {1,0}, {0,1}, {1,1} };
    CoreOut out;
    out.pos = float4(positions[vid], 0, 1);
    out.uv  = uvs[vid];
    return out;
}

fragment float4 core_frag(CoreOut in [[stage_in]],
                           constant OrbUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv * 2.0 - 1.0;
    float r = length(uv);

    // Core sits at center of viewport — small, restrained glow
    float glow = exp(-r * r * 14.0) * 0.55;
    if (u.orbState == STATE_PROCESSING) {
        glow *= 1.0 + 0.3 * sin(u.time * 6.0);
    } else if (u.orbState == STATE_ERROR) {
        glow *= 0.4 + 0.3 * step(0.5, fract(u.time * 9.0));
    }

    float3 coreColor = mix(float3(0.95, 0.97, 1.0), themeAccent(u.orbState), 0.22);
    return float4(coreColor * glow, glow);
}
