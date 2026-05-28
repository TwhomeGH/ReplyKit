#include <metal_stdlib>
using namespace metal;

struct Params {
    uint srcWidth;
    uint srcHeight;
    uint dstWidth;
    uint dstHeight;
    uint oDstW;       // 額外目標寬
    uint oDstH;       // 額外目標高
    uint angle;       // 0 / 90 / 180 / 270
};

// --- Catmull-Rom 1D interpolation ---
half catmullRom1D(half4 p, half t) {
    half t2 = t * t;
    half t3 = t2 * t;
    return 0.5h * ((2.0h * p[1]) +
                   (-p[0] + p[2]) * t +
                   (2.0h * p[0] - 5.0h * p[1] + 4.0h * p[2] - p[3]) * t2 +
                   (-p[0] + 3.0h * p[1] - 3.0h * p[2] + p[3]) * t3);
}

half2 catmullRom1D_uv(half2 p0, half2 p1, half2 p2, half2 p3, half t) {
    half t2 = t * t;
    half t3 = t2 * t;
    return 0.5h * ((2.0h * p1) +
                   (-p0 + p2) * t +
                   (2.0h * p0 - 5.0h * p1 + 4.0h * p2 - p3) * t2 +
                   (-p0 + 3.0h * p1 - 3.0h * p2 + p3) * t3);
}

// --- True 16-tap Catmull-Rom bicubic for Y plane ---
half bicubicSampleY_16tap(
    texture2d<half, access::sample> tex,
    float2 uv_px,
    uint2 texSize
) {
    float2 p = uv_px - 0.5f;
    int2 ip = int2(floor(p));
    float2 f = p - float2(ip);
    float2 texSizeF = float2(texSize);

    half4 rows[4];
    for (int row = 0; row < 4; row++) {
        int y = clamp(ip.y + row - 1, 0, int(texSize.y) - 1);

        half4 cols;
        for (int col = 0; col < 4; col++) {
            int x = clamp(ip.x + col - 1, 0, int(texSize.x) - 1);
            float2 norm = (float2(x, y) + 0.5f) / texSizeF;
            cols[col] = tex.sample(nearestClampSampler, norm).x;
        }

        rows[row] = catmullRom1D(cols, half(f.x));
    }

    half4 rowsVec = half4(rows[0], rows[1], rows[2], rows[3]);
    return catmullRom1D(rowsVec, half(f.y));
}

// --- True 16-tap Catmull-Rom bicubic for UV plane ---
half2 bicubicSampleUV_16tap(
    texture2d<half, access::sample> tex,
    float2 uv_px,
    uint2 texSize
) {
    float2 p = uv_px - 0.5f;
    int2 ip = int2(floor(p));
    float2 f = p - float2(ip);
    float2 texSizeF = float2(texSize);

    half2 rows[4];
    for (int row = 0; row < 4; row++) {
        int y = clamp(ip.y + row - 1, 0, int(texSize.y) - 1);

        half2 cols[4];
        for (int col = 0; col < 4; col++) {
            int x = clamp(ip.x + col - 1, 0, int(texSize.x) - 1);
            float2 norm = (float2(x, y) + 0.5f) / texSizeF;
            cols[col] = tex.sample(nearestClampSampler, norm).rg;
        }

        rows[row] = catmullRom1D_uv(cols[0], cols[1], cols[2], cols[3], half(f.x));
    }

    return catmullRom1D_uv(rows[0], rows[1], rows[2], rows[3], half(f.y));
}

inline float2 mapDstToSrc(
    float2 dstPx,
    uint srcW,
    uint srcH,
    uint outW,
    uint outH,
    uint angle
) {
    uint rotW = (angle % 180 == 0) ? srcW : srcH;
    uint rotH = (angle % 180 == 0) ? srcH : srcW;

    float scaleX = float(outW) / float(rotW);
    float scaleY = float(outH) / float(rotH);
    float uniformScale = min(scaleX, scaleY);

    float2 scaledSize = float2(rotW, rotH) * uniformScale;
    float2 offset = (float2(outW, outH) - scaledSize) * 0.5f;

    // dst -> rotated-image space
    float2 p = (dstPx - offset) / uniformScale;

    float2x2 R;
    switch (angle) {
    case 0:
        R = float2x2(1, 0, 0, 1);
        break;
    case 90:
        R = float2x2(0, 1, -1, 0);
        break;
    case 180:
        R = float2x2(-1, 0, 0, -1);
        break;
    default: // 270
        R = float2x2(0, -1, 1, 0);
        break;
    }

    float2 rotCenter = float2(rotW, rotH) * 0.5f;
    float2 srcCenter = float2(srcW, srcH) * 0.5f;

    // Rotate around image center instead of the top-left corner.
    return R * (p - rotCenter) + srcCenter;
}




constexpr sampler linearClampSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);

constexpr sampler nearestClampSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::nearest
);




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
    float2 src = mapDstToSrc(dst, W, H, outW, outH, params.angle);

    float srcXf = src.x;
    float srcYf = src.y;

    // --- Y bilinear ---
    if (srcXf < 0.0f || srcXf > float(W - 1) ||
        srcYf < 0.0f || srcYf > float(H - 1)) {

        // 超出範圍 → 黑邊
        dstY.write(half(0.0), gid);

    } else {

        half yVal = srcY.sample(
            linearClampSampler,
            float2(srcXf / float(W), srcYf / float(H))
        ).x;

        dstY.write(yVal, gid);
    }

    // --- UV bilinear ---
    // Only one thread writes each 2x2 chroma sample to avoid NV12 UV write races.
    if (((gid.x & 1u) == 0u) && ((gid.y & 1u) == 0u)) {
        uint2 uvPos = uint2(gid.x >> 1, gid.y >> 1);

        // Use src (Y plane coord) for bounds check, uvSrc = src * 0.5 for UV sampling
        if (src.x < 0.0f || src.x > float(W - 1) ||
            src.y < 0.0f || src.y > float(H - 1)) {

            dstUV.write(
                half4(0.5, 0.5, 0.0, 1.0),
                uvPos
            );

        } else {
            float2 uvSrc = src * 0.5f;
            float2 uvNorm = (clamp(uvSrc, 0.0f, float2(float(W) * 0.5f - 1.0f, float(H) * 0.5f - 1.0f)) + 0.5f) / float2(float(W) * 0.5f, float(H) * 0.5f);

            half2 uvVal = srcUV.sample(
                linearClampSampler,
                uvNorm
            ).rg;

            dstUV.write(
                half4(uvVal.x, uvVal.y, 0.0, 1.0),
                uvPos
            );
        }
    }

}

// --- Main kernel ---
kernel void rotateNV12_bicubic(
    texture2d<half, access::sample> srcY   [[ texture(0) ]],
    texture2d<half, access::sample> srcUV  [[ texture(1) ]],
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
    float2 src = mapDstToSrc(dst, W, H, outW, outH, params.angle);

    float srcXf = src.x;
    float srcYf = src.y;

    half yVal;

    if (srcXf < 0.0f || srcXf > float(W - 1) ||
    srcYf < 0.0f || srcYf > float(H - 1)) {

    yVal = half(0.0);

    } else {

        yVal = bicubicSampleY_16tap(
            srcY,
            float2(srcXf, srcYf),
            uint2(srcY.get_width(), srcY.get_height())
        );

    }

    dstY.write(yVal, gid);

    // --- UV bicubic (true 16-tap Catmull-Rom) ---
    if (((gid.x & 1u) == 0u) && ((gid.y & 1u) == 0u)) {
        uint2 uvPos = uint2(gid.x >> 1, gid.y >> 1);

        if (src.x < 0.0f || src.x > float(W - 1) ||
            src.y < 0.0f || src.y > float(H - 1)) {

            dstUV.write(half4(0.5, 0.5, 0.0, 1.0), uvPos);

        } else {
            float2 uvSrc = src * 0.5f;
            float2 uvClamped = clamp(uvSrc, 0.0f, float2(float(W) * 0.5f - 1.0f, float(H) * 0.5f - 1.0f));

            half2 uvVal = bicubicSampleUV_16tap(
                srcUV,
                uvClamped,
                uint2(srcUV.get_width(), srcUV.get_height())
            );

            dstUV.write(
                half4(uvVal.x, uvVal.y, 0.0, 1.0),
                uvPos
            );
        }
    }

}
