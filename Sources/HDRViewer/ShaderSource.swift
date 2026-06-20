/// Metal shader source embedded as a string so no SPM resource bundle is needed.
/// Compiled at runtime via `device.makeLibrary(source:options:)`.
///
/// Color pipeline (all linear light):
///   working RGB --(uni.rgbToXYZ, per frame)--> XYZ(D50)
///               --(Bradford)--> XYZ(D65)
///               --(constant)--> linear Display-P3
/// The result is written to an `extendedLinearDisplayP3` RGBA16Float drawable,
/// where 1.0 == SDR reference white and values up to the display's EDR headroom
/// are shown brighter. We do NOT tone map on HDR displays: values pass through
/// and the compositor/display clips at its peak (WYSIWYG, as pro grading tools
/// do). On SDR displays (headroom <= 1) a Reinhard curve preserves highlights.
let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

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

// Fraction of the display headroom at which the soft shoulder begins. Below
// knee = SHOULDER_START * headroom the signal passes through 1:1 (WYSIWYG);
// above it a C1-continuous roll-off compresses gently to the panel ceiling.
constant float SHOULDER_START = 0.80f;

// Soft shoulder for luminance above the knee. Maps [knee, +inf) -> [knee, ceil)
// with value=knee and slope=1 at x==knee (C1-continuous with the linear
// pass-through), asymptoting to ceil. Returns the mapped luminance.
float softShoulder(float lum, float knee, float ceil)
{
    if(lum <= knee) {
        return lum;                       // pass-through: WYSIWYG below the knee
    }
    float span = max(ceil - knee, 1e-6f); // remaining headroom above the knee
    float x    = lum - knee;              // excess over the knee
    return knee + span * x / (x + span);  // rational roll-off, slope 1 at x=0
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

    // Soft gamut compression: colors outside Display-P3 yield negative channels.
    // Pull them toward the achromatic axis instead of hard-clamping (which would
    // create a visible flat edge), then clamp any residual negatives to zero.
    float minVal = min(min(p3.r, p3.g), p3.b);
    if(minVal < 0.0f) {
        float lum = max(dot(p3, LUM_P3), 0.0f);
        float t = minVal / (minVal - lum + 1e-6f);
        p3 = mix(p3, float3(lum), saturate(t));
    }
    p3 = max(p3, float3(0.0f));

    const float headroom = max(uni.edrHeadroom, 1.0f);

    // Over-range detection (any channel or luminance beyond headroom) for the
    // optional clipping warning.
    const float lum  = max(dot(p3, LUM_P3), 1e-6f);
    const float maxC = max(max(p3.r, p3.g), p3.b);
    bool overRange   = (maxC > headroom) || (lum > headroom);

    // Dynamic-range mapping. Always operate on LUMINANCE and apply a single
    // scalar (lum_out / lum) to all channels, so chromaticity is preserved and
    // no channel clips independently (which would tint highlights magenta/green).
    if(headroom > 1.0f) {
        // HDR display: WYSIWYG. Display-referred values pass through unchanged
        // up to the knee (1.0 -> reference white; (1.0, knee] shown brighter),
        // then a soft shoulder rolls [knee, +inf) into the panel ceiling so the
        // brightest super-whites never hard-clip. THIS is what makes >1.0
        // highlights actually appear brighter than paper white.
        const float knee  = SHOULDER_START * headroom;
        const float lum_t = softShoulder(lum, knee, headroom);
        p3 *= lum_t / lum;
    } else {
        // SDR display (no headroom): ratio-preserving Reinhard to [0,1] to keep
        // highlight detail. [0,+inf) -> [0,1), chromaticity preserved.
        const float lum_t = lum / (1.0f + lum);
        p3 *= lum_t / lum;
    }

    p3 = max(p3, float3(0.0f));

    if(uni.showClipping > 0.5f && overRange) {
        // Flag over-range pixels with magenta at SDR white so they stand out.
        p3 = float3(1.0f, 0.0f, 1.0f);
    }

    return half4(half3(p3), 1.0h);
}
"""
