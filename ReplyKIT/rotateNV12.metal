#include <metal_stdlib>
using namespace metal;

struct Params {
    uint srcWidth;
    uint srcHeight;
    uint dstWidth;
    uint dstHeight;
    uint oDstW;
    uint oDstH;
    float rot00, rot01, rot10, rot11;
    float rotCenterX, rotCenterY;
    float srcCenterX, srcCenterY;
    float halfW, halfH;
    float uniformScale;
    float offsetX, offsetY;
};

struct OverlayCompositeParams {
    uint originX;
    uint originY;
    uint overlayWidth;
    uint overlayHeight;
    uint dstWidth;
    uint dstHeight;
    float opacity;
};

// --- Catmull-Rom 1D interpolation (float precision) ---
float catmullRom1D(float4 p, float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return 0.5f * ((2.0f * p[1]) +
                   (-p[0] + p[2]) * t +
                   (2.0f * p[0] - 5.0f * p[1] + 4.0f * p[2] - p[3]) * t2 +
                   (-p[0] + 3.0f * p[1] - 3.0f * p[2] + p[3]) * t3);
}


constexpr sampler linearClampSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);

float2 catmullRom1D2(float2 p0, float2 p1, float2 p2, float2 p3, float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return 0.5f * ((2.0f * p1) +
                   (-p0 + p2) * t +
                   (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * t2 +
                   (-p0 + 3.0f * p1 - 3.0f * p2 + p3) * t3);
}

float sampleYAtPixel(texture2d<half, access::read> tex, float2 pixel, float2 texSize) {
    float2 clamped = clamp(pixel, float2(0.0), texSize - 1.0);
    return float(tex.read(uint2(clamped)).x);
}

float2 sampleUVAtPixel(texture2d<half, access::read> tex, float2 pixel, float2 texSize) {
    float2 clamped = clamp(pixel, float2(0.0), texSize - 1.0);
    return float2(tex.read(uint2(clamped)).rg);
}

// Pixel-coordinate Catmull-Rom bicubic. Keep quality mode correct before re-optimizing.
float bicubicSampleY_16tap(texture2d<half, access::read> tex, float2 pixel, float2 texSize) {
    float2 base = floor(pixel);
    float2 f = fract(pixel);

    float4 row;
    for (int j = -1; j <= 2; j++) {
        float y = base.y + float(j);
        float4 col = float4(
            sampleYAtPixel(tex, float2(base.x - 1.0, y), texSize),
            sampleYAtPixel(tex, float2(base.x, y), texSize),
            sampleYAtPixel(tex, float2(base.x + 1.0, y), texSize),
            sampleYAtPixel(tex, float2(base.x + 2.0, y), texSize)
        );
        row[j + 1] = catmullRom1D(col, f.x);
    }

    return clamp(catmullRom1D(row, f.y), 0.0, 1.0);
}

float2 bicubicSampleUV_16tap(texture2d<half, access::read> tex, float2 pixel, float2 texSize) {
    float2 base = floor(pixel);
    float2 f = fract(pixel);

    float2 row[4];
    for (int j = -1; j <= 2; j++) {
        float y = base.y + float(j);
        float2 c0 = sampleUVAtPixel(tex, float2(base.x - 1.0, y), texSize);
        float2 c1 = sampleUVAtPixel(tex, float2(base.x, y), texSize);
        float2 c2 = sampleUVAtPixel(tex, float2(base.x + 1.0, y), texSize);
        float2 c3 = sampleUVAtPixel(tex, float2(base.x + 2.0, y), texSize);
        row[j + 1] = catmullRom1D2(c0, c1, c2, c3, f.x);
    }

    return clamp(catmullRom1D2(row[0], row[1], row[2], row[3], f.y), 0.0, 1.0);
}

inline float2 mapDstToSrc(
    float2 dstPx,
    constant Params& params
) {
    float2 p = (dstPx - float2(params.offsetX, params.offsetY)) / params.uniformScale;
    float2x2 R = float2x2(params.rot00, params.rot01, params.rot10, params.rot11);
    float2 rotCenter = float2(params.rotCenterX, params.rotCenterY);
    float2 srcCenter = float2(params.srcCenterX, params.srcCenterY);
    return R * (p - rotCenter) + srcCenter;
}

inline float3 rgbToYuv(float3 rgb) {
    float y = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b;
    float u = -0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b + 0.5;
    float v = 0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b + 0.5;
    return float3(y, u, v);
}

kernel void compositeOverlayBGRAToNV12(
    texture2d<half, access::read> overlay [[ texture(0) ]],
    texture2d<half, access::read_write> dstY [[ texture(1) ]],
    texture2d<half, access::read_write> dstUV [[ texture(2) ]],
    constant OverlayCompositeParams& params [[ buffer(0) ]],
    uint2 gid [[ thread_position_in_grid ]]
) {
    if (gid.x >= params.overlayWidth || gid.y >= params.overlayHeight) return;

    uint2 dstPos = uint2(params.originX + gid.x, params.originY + gid.y);
    if (dstPos.x >= params.dstWidth || dstPos.y >= params.dstHeight) return;

    uint2 overlayPos = uint2(gid.x, params.overlayHeight - 1u - gid.y);
    float4 rgba = float4(overlay.read(overlayPos));
    float alpha = clamp(rgba.a * params.opacity, 0.0, 1.0);
    if (alpha <= 0.001) return;

    float3 rgb = clamp(rgba.rgb / max(rgba.a, 0.001), 0.0, 1.0);
    float3 yuv = rgbToYuv(rgb);
    float oldY = float(dstY.read(dstPos).r);
    float newY = mix(oldY, yuv.x, alpha);
    dstY.write(half(newY), dstPos);

    if (((dstPos.x & 1u) == 0u) && ((dstPos.y & 1u) == 0u)) {
        float2 uvAcc = float2(0.0);
        float alphaAcc = 0.0;

        for (uint oy = 0; oy < 2; oy++) {
            for (uint ox = 0; ox < 2; ox++) {
                uint2 samplePos = gid + uint2(ox, oy);
                if (samplePos.x >= params.overlayWidth || samplePos.y >= params.overlayHeight) {
                    continue;
                }
                uint2 overlaySamplePos = uint2(samplePos.x, params.overlayHeight - 1u - samplePos.y);
                float4 sampleRGBA = float4(overlay.read(overlaySamplePos));
                float sampleAlpha = clamp(sampleRGBA.a * params.opacity, 0.0, 1.0);
                if (sampleAlpha <= 0.001) {
                    continue;
                }
                float3 sampleRGB = clamp(sampleRGBA.rgb / max(sampleRGBA.a, 0.001), 0.0, 1.0);
                float3 sampleYUV = rgbToYuv(sampleRGB);
                uvAcc += sampleYUV.yz * sampleAlpha;
                alphaAcc += sampleAlpha;
            }
        }

        if (alphaAcc > 0.001) {
            uint2 uvPos = uint2(dstPos.x >> 1, dstPos.y >> 1);
            float uvAlpha = clamp(alphaAcc * 0.25, 0.0, 1.0);
            float2 overlayUV = uvAcc / alphaAcc;
            float2 oldUV = float2(dstUV.read(uvPos).rg);
            float2 newUV = mix(oldUV, overlayUV, uvAlpha);
            dstUV.write(half4(half2(half(newUV.x), half(newUV.y)), 0.0h, 1.0h), uvPos);
        }
    }
}

// A 線性方法
kernel void rotateNV12_bilinear(
    texture2d<half, access::sample> srcY   [[ texture(0) ]],
    texture2d<half, access::sample> srcUV  [[ texture(1) ]],
    texture2d<half, access::write>  dstY   [[ texture(2) ]],
    texture2d<half, access::write>  dstUV  [[ texture(3) ]],
    constant Params& params                [[ buffer(0) ]],
    uint2 gid                              [[ thread_position_in_grid ]]
) {




    uint W = params.srcWidth;
    uint H = params.srcHeight;
    uint dstW = params.dstWidth;
    uint dstH = params.dstHeight;


    // 決定最終輸出寬高
    uint outW = (params.oDstW > 0) ? params.oDstW : dstW;
    uint outH = (params.oDstH > 0) ? params.oDstH : dstH;

    if (gid.x >= outW || gid.y >= outH) return;

    float2 dst = float2(gid) + 0.5f;
    float2 src = mapDstToSrc(dst, params);

    float srcXf = src.x;
    float srcYf = src.y;

    // --- Y bilinear ---
    if (srcXf < 0.0f || srcXf > float(W - 1) ||
        srcYf < 0.0f || srcYf > float(H - 1)) {
        dstY.write(half(0.0), gid);
    } else {
        half yVal = srcY.sample(
            linearClampSampler,
            float2(srcXf / float(W), srcYf / float(H))
        ).x;
        dstY.write(yVal, gid);
    }

    // --- UV bilinear ---
    if (((gid.x & 1u) == 0u) && ((gid.y & 1u) == 0u)) {
        uint2 uvPos = uint2(gid.x >> 1, gid.y >> 1);

        if (src.x < 0.0f || src.x > float(W - 1) ||
            src.y < 0.0f || src.y > float(H - 1)) {
            dstUV.write(half4(0.5h, 0.5h, 0.0h, 1.0h), uvPos);
        } else {
            float2 uvSrc = src * 0.5f;
            float2 uvClamped = clamp(uvSrc, 0.0f, float2(params.halfW - 1.0f, params.halfH - 1.0f));
            float2 uvNorm = (uvClamped + 0.5f) / float2(params.halfW, params.halfH);
            half2 uvVal = srcUV.sample(linearClampSampler, uvNorm).rg;
            dstUV.write(half4(uvVal.x, uvVal.y, 0.0h, 1.0h), uvPos);
        }
    }
}

// --- Bicubic kernel ---
kernel void rotateNV12_bicubic(
    texture2d<half, access::read> srcY   [[ texture(0) ]],
    texture2d<half, access::read> srcUV  [[ texture(1) ]],
    texture2d<half, access::write> dstY  [[ texture(2) ]],
    texture2d<half, access::write> dstUV  [[ texture(3) ]],
    constant Params& params               [[ buffer(0) ]],
    uint2 gid                             [[ thread_position_in_grid ]]
                                     ) {

    uint W = params.srcWidth;
    uint H = params.srcHeight;
    uint dstW = params.dstWidth;
    uint dstH = params.dstHeight;

    // 決定最終輸出寬高
    uint outW = (params.oDstW > 0) ? params.oDstW : dstW;
    uint outH = (params.oDstH > 0) ? params.oDstH : dstH;

    if (gid.x >= outW || gid.y >= outH) return;
    float2 dst = float2(gid) + 0.5f;
    float2 src = mapDstToSrc(dst, params);

    float srcXf = src.x;
    float srcYf = src.y;

    // --- Y bicubic ---
    if (srcXf < 0.0f || srcXf > float(W - 1) ||
        srcYf < 0.0f || srcYf > float(H - 1)) {
        dstY.write(half(0.0), gid);
    } else {
        float yF = bicubicSampleY_16tap(
            srcY,
            float2(srcXf, srcYf),
            float2(srcY.get_width(), srcY.get_height())
        );
        dstY.write(half(yF), gid);
    }

    // --- UV bicubic ---
    if (((gid.x & 1u) == 0u) && ((gid.y & 1u) == 0u)) {
        uint2 uvPos = uint2(gid.x >> 1, gid.y >> 1);

        if (src.x < 0.0f || src.x > float(W - 1) ||
            src.y < 0.0f || src.y > float(H - 1)) {
            dstUV.write(half4(0.5h, 0.5h, 0.0h, 1.0h), uvPos);
        } else {
            float2 uvSrc = src * 0.5f;
            float2 uvClamped = clamp(uvSrc, 0.0f, float2(params.halfW - 1.0f, params.halfH - 1.0f));

            float2 uvF = bicubicSampleUV_16tap(
                srcUV,
                uvClamped,
                float2(srcUV.get_width(), srcUV.get_height())
            );

            dstUV.write(
                half4(half(uvF.x), half(uvF.y), 0.0h, 1.0h),
                uvPos
            );
        }
    }
}
