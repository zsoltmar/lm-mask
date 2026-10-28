// Compositor.metal
// One render pass, draws into the output frame:
//   1. camera frame        (fullscreen triangle, no blending)
//   2. mouth patch         (12x6 grid over the projected mouth-window quad, premultiplied-alpha blend, hard rounded-rect clip)
//   3. 3D mask texture     (fullscreen triangle, premultiplied-alpha blend; its windows are transparent holes with a blue tint)
//   4. scare vignette / flash
//
// Metal Shading Language spec: https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
// Render pipeline blending:    https://developer.apple.com/documentation/metal/mtlrenderpipelinecolorattachmentdescriptor
// Texture coordinates here are top-left origin, matching CVPixelBuffer rows and SceneKit offscreen output.

#include <metal_stdlib>
using namespace metal;

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

// Single oversized triangle covering the viewport: ids 0,1,2 -> (0,0) (2,0) (0,2).
vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    FullscreenOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

/// `crop` = (origin.xy, size.zw) of the visible source region in normalised source UV (FrameMapping.uvOrigin/uvSize).
/// Aspect-fill: the camera is never stretched, overflow is cropped by sampling a sub-rectangle.
/// `shift` = scare screen shake as a normalised output-UV offset (content moves by +shift); (0,0) normally.
fragment float4 cameraFragment(FullscreenOut in [[stage_in]],
                               texture2d<float> camera [[texture(0)]],
                               constant float4 &crop [[buffer(0)]],
                               constant float2 &shift [[buffer(1)]]) {
    return float4(camera.sample(linearClamp, crop.xy + (in.uv - shift) * crop.zw).rgb, 1.0);
}

/// `premultiplyMask` = 1 if the 3D pass wrote straight (non-premultiplied) colour, 0 if already premultiplied.
fragment float4 maskFragment(FullscreenOut in [[stage_in]],
                             texture2d<float> mask [[texture(0)]],
                             constant float &premultiplyMask [[buffer(0)]],
                             constant float2 &shift [[buffer(1)]]) {
    float4 c = mask.sample(linearClamp, in.uv - shift);
    c.rgb = mix(c.rgb, c.rgb * c.a, premultiplyMask);
    return c;
}

// Layout mirrors `ScareUniforms` in Compositor.swift (4 floats).
struct ScareUniforms {
    float amount;     // 0...1 scareAmount
    float flash;      // 0...1 white-ish flash alpha (first 2 frames)
    float vignette;   // 0...1 strength
    float flicker;    // ~1 +- 0.08
};

/// Last draw of the frame (premultiplied blend): dark red vignette that grows with `scareAmount`, plus a one-shot flash.
fragment float4 scareFragment(FullscreenOut in [[stage_in]],
                              constant ScareUniforms &u [[buffer(0)]]) {
    const float2 q = (in.uv * 2.0 - 1.0) * float2(0.85, 1.0);   // roughly circular on 16:9
    const float edge = smoothstep(0.35, 1.2, length(q));
    // A little darkening everywhere (mood), a lot at the edges.
    const float va = clamp(u.amount * (0.10 + 0.80 * u.vignette * edge * u.flicker), 0.0, 0.95);
    const float3 vigRGB = float3(0.16, 0.0, 0.0) * va;          // premultiplied dark red: darkens and tints red
    const float fa = clamp(u.flash, 0.0, 1.0);
    const float3 flashRGB = float3(1.0, 0.96, 0.92) * fa;
    return float4(flashRGB + (1.0 - fa) * vigRGB, fa + (1.0 - fa) * va);
}

// Layout mirrors `MouthUniforms` in Compositor.swift (11 x float2, 88 bytes, no padding).
struct MouthUniforms {
    float2 c0;          // the mouth WINDOW's corners in output pixels (top-left origin):
    float2 c1;          //   c0 top-left, c1 top-right, c2 bottom-right, c3 bottom-left (window's own orientation)
    float2 c2;
    float2 c3;
    float2 cropCenter;  // camera pixels
    float2 cropHalf;    // camera pixels, already fitted to the window's aspect
    float2 camSize;     // camera size in pixels
    float2 outSize;     // output size in pixels
    float2 shape;       // x = window width / height, y = corner radius as a fraction of the height
    float2 rot;         // cos, sin of the face's visual clockwise roll
};

struct MouthOut {
    float4 position [[position]];
    float2 t;           // 0...1 across the window, y down
};

constant int kGridX = 12;
constant int kGridY = 6;

/// Procedural 12x6 grid (432 vertices, no vertex buffer) over the projected window quad (bilinear in its four corners,
/// so it follows roll / yaw / pitch of the mask).
vertex MouthOut mouthVertex(uint vid [[vertex_id]],
                            constant MouthUniforms &u [[buffer(0)]]) {
    const uint quad = vid / 6u;
    const uint k = vid % 6u;
    const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
    const float2 cell = float2(float(quad % uint(kGridX)), float(quad / uint(kGridX)));
    const float2 t = (cell + corners[k]) / float2(float(kGridX), float(kGridY));  // 0...1, y down
    const float2 top = mix(u.c0, u.c1, t.x);
    const float2 bottom = mix(u.c3, u.c2, t.x);
    const float2 px = mix(top, bottom, t.y);

    MouthOut out;
    out.position = float4(px.x / u.outSize.x * 2.0 - 1.0, 1.0 - px.y / u.outSize.y * 2.0, 0.0, 1.0);
    out.t = t;
    return out;
}

/// The user's mouth, clipped to the window's rounded rectangle with a HARD edge (one pixel of anti-aliasing, no feather),
/// scaled to fill the window. The patch is drawn under the mask, whose window hole has the same shape; the clip here is
/// grown by one pixel so a rounding difference never shows an un-patched sliver.
fragment float4 mouthFragment(MouthOut in [[stage_in]],
                              texture2d<float> camera [[texture(0)]],
                              constant MouthUniforms &u [[buffer(0)]]) {
    const float2 size = float2(u.shape.x, 1.0);                 // window in units of its height
    const float2 p = (in.t - 0.5) * size;
    const float r = u.shape.y;
    const float2 q = abs(p) - size * 0.5 + r;
    const float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;   // signed distance, < 0 inside
    const float fw = max(fwidth(d), 1e-5);
    const float a = clamp(0.5 - (d - fw) / fw, 0.0, 1.0);

    const float2 cp = (in.t * 2.0 - 1.0) * u.cropHalf;           // camera pixels from the crop centre
    const float2 rp = float2(u.rot.x * cp.x - u.rot.y * cp.y, u.rot.y * cp.x + u.rot.x * cp.y);
    const float2 uv = (u.cropCenter + rp) / u.camSize;
    const float3 rgb = camera.sample(linearClamp, uv).rgb;
    return float4(rgb * a, a);
}
