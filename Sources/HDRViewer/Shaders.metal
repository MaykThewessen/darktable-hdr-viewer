#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// NOTE: This file is the readable reference copy of the shaders. The app
// compiles the identical source embedded in ShaderSource.swift at runtime
// (it is excluded from the SPM target). Keep the two in sync.
// ---------------------------------------------------------------------------
//
// Color pipeline (all linear light):
//   working RGB --(uni.rgbToXYZ, per frame)--> XYZ(D50)
//               --(Bradford)--> XYZ(D65)
//               --(constant)--> linear Display-P3
// Output goes to an extendedLinearDisplayP3 RGBA16Float drawable, where 1.0 ==
// SDR reference white and values up to the display's EDR headroom are shown
// brighter. No tone mapping on HDR displays (WYSIWYG; the display clips at its
// peak). On SDR displays a Reinhard curve preserves highlight detail.

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex VertexOut vertexPassthrough(uint vid [[vertex_id]])
{
    const float2 positions[3] = {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f)
    };
    const float2 texcoords[3] = {
        float2(0.0f, 1.0f),
        float2(2.0f, 1.0f),
        float2(0.0f, -1.0f)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0.0f, 1.0f);
    out.texcoord = texcoords[vid];
    return out;
}

// Layout must match `struct Uniforms` in HDRMetalView.swift.
struct Uniforms {
    float3x3 rgbToXYZ;     // working RGB -> XYZ(D50), supplied per frame
    float    edrHeadroom;  // display max EDR component value (>= 1.0)
    float    showClipping; // 0 or 1: highlight over-range pixels
    float    _pad0;
    float    _pad1;
};

// Bradford chromatic adaptation XYZ(D50) -> XYZ(D65). Columns for M * v.
constant float3x3 BRADFORD_D50_TO_D65 = float3x3(
    float3( 0.9555766f, -0.0282895f,  0.0122982f),
    float3(-0.0230393f,  1.0099416f, -0.0204830f),
    float3( 0.0631636f,  0.0210077f,  1.3299098f)
);

// XYZ(D65) -> linear Display-P3. Columns for M * v.
constant float3x3 XYZ_D65_TO_DISPLAY_P3 = float3x3(
    float3( 2.4934969f, -0.8294890f,  0.0358458f),
    float3(-0.9313836f,  1.7626641f, -0.0761724f),
    float3(-0.4027108f,  0.0236247f,  0.9568845f)
);

constant float3 LUM_P3 = float3(0.2290f, 0.6917f, 0.0793f); // P3 luminance weights

// Reinhard global tone map, used only on SDR displays to retain highlight detail.
float3 reinhardSDR(float3 c)
{
    float lum = max(dot(c, LUM_P3), 0.0f);
    float scale = (lum > 0.0f) ? ((lum / (1.0f + lum)) / lum) : 0.0f;
    return c * scale;
}

fragment half4 fragmentHDR(
    VertexOut          in     [[stage_in]],
    texture2d<float>   srcTex [[texture(0)]],
    sampler            smp    [[sampler(0)]],
    constant Uniforms& uni    [[buffer(0)]])
{
    float3 rgb = srcTex.sample(smp, in.texcoord).rgb;

    // working primaries -> XYZ(D50) -> XYZ(D65) -> linear Display-P3
    float3 xyz = uni.rgbToXYZ * rgb;
    xyz        = BRADFORD_D50_TO_D65 * xyz;
    float3 p3  = XYZ_D65_TO_DISPLAY_P3 * xyz;

    // Soft gamut compression for colors outside Display-P3 (negative channels).
    float minVal = min(min(p3.r, p3.g), p3.b);
    if(minVal < 0.0f) {
        float lum = max(dot(p3, LUM_P3), 0.0f);
        float t = minVal / (minVal - lum + 1e-6f);
        p3 = mix(p3, float3(lum), saturate(t));
    }
    p3 = max(p3, float3(0.0f));

    const float headroom = max(uni.edrHeadroom, 1.0f);
    bool overRange = (max(max(p3.r, p3.g), p3.b) > headroom);

    // Ratio-preserving Reinhard mapped to the EDR headroom: [0,inf)->[0,headroom).
    // Scales by a luminance curve and keeps color ratios, so scene-referred
    // super-white never clips per-channel (which tinted highlights magenta/green).
    // On SDR (headroom==1) this is plain Reinhard to [0,1].
    {
        const float lum = max(dot(p3, LUM_P3), 1e-6f);
        const float lum_t = headroom * lum / (lum + headroom);
        p3 *= lum_t / lum;
    }

    if(uni.showClipping > 0.5f && overRange) {
        p3 = float3(1.0f, 0.0f, 1.0f); // magenta clip marker
    }

    return half4(half3(p3), 1.0h);
}
