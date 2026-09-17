// The desktop, drawn as one textured quad.
//
// There is nothing clever to do here and that is the point: the density
// extension makes the framebuffer the size of the window's backing store, so
// the quad covers the drawable exactly and every texel lands on its own pixel.
// The sampler only ever does anything during the moment between a window
// resizing and the desktop following it.
#include <metal_stdlib>
using namespace metal;

struct Varying {
    float4 position [[position]];
    float2 uv;
};

/// `fit` is where the desktop goes in clip space: origin in xy, size in zw.
/// A strip of four corners, so no vertex buffer and no index buffer.
vertex Varying desktop_vertex(uint id [[vertex_id]], constant float4 &fit [[buffer(0)]]) {
    float2 corner = float2(id & 1, id >> 1);
    Varying out;
    out.position = float4(fit.xy + corner * fit.zw, 0.0, 1.0);
    // Clip space counts up the screen and the framebuffer's rows count down it.
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

fragment float4 desktop_fragment(Varying in [[stage_in]], texture2d<float> desktop [[texture(0)]], sampler smooth [[sampler(0)]]) {
    // The framebuffer's fourth byte is padding, not alpha: the desktop is
    // opaque whatever happens to be in it.
    return float4(desktop.sample(smooth, in.uv).rgb, 1.0);
}
