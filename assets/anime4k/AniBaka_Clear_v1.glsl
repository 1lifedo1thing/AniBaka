//!DESC AniBaka Clear v3 - Low Bitrate Cleanup
//!HOOK MAIN
//!BIND HOOKED
//!WIDTH HOOKED.w
//!HEIGHT HOOKED.h

// Keep the asset filename for existing presets. Run BEFORE Anime4K Restore
// and Upscale: one source-resolution pass, 13 texture reads, no history buffer.
// This is conservative artifact suppression, not recovery of lost detail.
// Leave deblurring to Anime4K: real-video comparisons showed that pre-sharpening
// stacked with Restore hardens contours and moves them away from the reference.
const float AB_DENOISE = 0.55;
const float AB_DEBLOCK = 0.30;

float ab_luma(vec3 rgb) {
    return dot(rgb, vec3(0.2126, 0.7152, 0.0722));
}

// Reject real colour boundaries as well as luma boundaries. In particular,
// equal-luma colours must not bleed into each other during cleanup.
float ab_range(vec3 neighbour, vec3 centre) {
    vec3 d = abs(neighbour - centre);
    return 1.0 - smoothstep(0.025, 0.100, max(d.r, max(d.g, d.b)));
}

// A small jump between locally flat sides is likely a compression step.
// Wide, gradual transitions should instead be left for line restoration.
// No fixed 8/16-pixel grid: cropping/resizing and modern codecs break it.
float ab_block(float ll, float l, float c, float r, float rr) {
    float dl = abs(c - l);
    float dr = abs(r - c);
    float jump = max(dl, dr);
    float sides = abs(ll - l) + abs(rr - r) + min(dl, dr);
    return smoothstep(0.002, 0.012, jump) *
           (1.0 - smoothstep(0.025, 0.075, jump)) *
           (1.0 - smoothstep(0.004, 0.020, sides));
}

vec4 hook() {
    // texOff also respects mpv's texture rotation and pixel mapping.
    vec4 centre = HOOKED_texOff(vec2(0.0, 0.0));
    vec3 c = centre.rgb;
    vec3 n  = HOOKED_texOff(vec2( 0.0, -1.0)).rgb;
    vec3 ne = HOOKED_texOff(vec2( 1.0, -1.0)).rgb;
    vec3 e  = HOOKED_texOff(vec2( 1.0,  0.0)).rgb;
    vec3 se = HOOKED_texOff(vec2( 1.0,  1.0)).rgb;
    vec3 s  = HOOKED_texOff(vec2( 0.0,  1.0)).rgb;
    vec3 sw = HOOKED_texOff(vec2(-1.0,  1.0)).rgb;
    vec3 w  = HOOKED_texOff(vec2(-1.0,  0.0)).rgb;
    vec3 nw = HOOKED_texOff(vec2(-1.0, -1.0)).rgb;
    float yc = ab_luma(c);
    float yn = ab_luma(n), yne = ab_luma(ne), ye = ab_luma(e);
    float yse = ab_luma(se), ys = ab_luma(s), ysw = ab_luma(sw);
    float yw = ab_luma(w), ynw = ab_luma(nw);
    float ynn = ab_luma(HOOKED_texOff(vec2( 0.0, -2.0)).rgb);
    float yee = ab_luma(HOOKED_texOff(vec2( 2.0,  0.0)).rgb);
    float yss = ab_luma(HOOKED_texOff(vec2( 0.0,  2.0)).rgb);
    float yww = ab_luma(HOOKED_texOff(vec2(-2.0,  0.0)).rgb);

    float lo = min(yc, min(min(yn, ys), min(ye, yw)));
    lo = min(lo, min(min(yne, ysw), min(ynw, yse)));
    float hi = max(yc, max(max(yn, ys), max(ye, yw)));
    hi = max(hi, max(max(yne, ysw), max(ynw, yse)));
    float contrast = hi - lo;
    float block = max(ab_block(yww, yw, yc, ye, yee),
                      ab_block(ynn, yn, yc, ys, yss));

    // Reuse the 3x3 samples for an edge-stopping RGB average. This also
    // reduces low-amplitude chroma speckles, without sharpening chroma.
    float wn = 2.0 * ab_range(n, c), we = 2.0 * ab_range(e, c);
    float ws = 2.0 * ab_range(s, c), ww = 2.0 * ab_range(w, c);
    float wne = ab_range(ne, c), wse = ab_range(se, c);
    float wsw = ab_range(sw, c), wnw = ab_range(nw, c);
    float weights = 4.0 + wn + we + ws + ww + wne + wse + wsw + wnw;
    vec3 average = (4.0 * c + wn * n + we * e + ws * s + ww * w +
                    wne * ne + wse * se + wsw * sw + wnw * nw) / weights;
    float flatGate = 1.0 - smoothstep(0.025, 0.095, contrast);
    float cleanup = clamp(AB_DENOISE * flatGate + AB_DEBLOCK * block, 0.0, 1.0);
    // Positive normalized weights and a bounded blend preserve local RGB
    // extrema without a second luma conversion, Sobel pass or halo limiter.
    return vec4(mix(c, average, cleanup), centre.a);
}
