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

// --- Catmull-Rom 1D interpolation (float precision) ---
float catmullRom1D(float4 p, float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return 0.5f * ((2.0f * p[1]) +
                   (-p[0] + p[2]) * t +
                   (2.0f * p[0] - 5.0f * p[1] + 4.0f * p[2] - p[3]) * t2 +
                   (-p[0] + 3.0f * p[1] - 3.0f * p[2] + p[3]) * t3);
}

float2 catmullRom1D_uv(float2 p0, float2 p1, float2 p2, float2 p3, float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return 0.5f * ((2.0f * p1) +
                   (-p0 + p2) * t +
                   (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * t2 +
                   (-p0 + 3.0f * p1 - 3.0f * p2 + p3) * t3);
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

constexpr sampler pixelNearest(
    coord::pixel,
    address::clamp_to_edge,
    filter::nearest
);

// --- 4-tap texture bicubic for Y plane (uses bilinear hardware) ---
float bicubicSampleY_4tap(texture2d<half, access::sample> tex, float2 uv, float2 texSize) {
    float2 px = uv * texSize - 0.5;
    float2 f = fract(px);
    float2 i = floor(px);

    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);

    float2 w12 = w1 + w2;
    float2 offset12 = w2 / (w12 + 1e-10);
    float2 texelSize = 1.0 / texSize;

    float2 tc0 = (i - 0.5) * texelSize;
    float2 tc1 = (i + offset12) * texelSize;
    float2 tc2 = (i + 1.0 + offset12) * texelSize;
    float2 tc3 = (i + 1.5) * texelSize;

    float s0 = float(tex.sample(linearClampSampler, float2(tc0.x, uv.y)).x);
    float s1 = float(tex.sample(linearClampSampler, float2(tc1.x, uv.y)).x);
    float s2 = float(tex.sample(linearClampSampler, float2(tc2.x, uv.y)).x);
    float s3 = float(tex.sample(linearClampSampler, float2(tc3.x, uv.y)).x);

    float h0 = s1 * w12.x + s2 * (1.0 - w12.x);
    float h1 = s0 * (1.0 - w12.x) + s3 * w12.x;

    return h0 * (1.0 - f.y) + h1 * f.y;
}

// --- True 16-tap Catmull-Rom bicubic for Y plane (float precision) ---
float bicubicSampleY_16tap(
    texture2d<half, access::sample> tex,
    float2 uv_px,
    uint2 texSize
) {
    float2 p = uv_px - 0.5f;
    int2 ip = int2(floor(p));
    float2 f = p - float2(ip);
    float2 texSizeF = float2(texSize);

    float4 rows[4];
    for (int r = 0; r < 4; r++) {
        int y = clamp(ip.y + r - 1, 0, int(texSize.y) - 1);
        float4 col;
        for (int c = 0; c < 4; c++) {
            int x = clamp(ip.x + c - 1, 0, int(texSize.x) - 1);
            float2 norm = (float2(x, y) + 0.5f) / texSizeF;
            col[c] = float(tex.sample(nearestClampSampler, norm).x);
        }
        rows[r] = col;
    }

    float4 temp = float4(
        catmullRom1D(rows[0], f.x),
        catmullRom1D(rows[1], f.x),
        catmullRom1D(rows[2], f.x),
        catmullRom1D(rows[3], f.x)
    );
    return catmullRom1D(temp, f.y);
}

// --- True 16-tap Catmull-Rom bicubic for UV plane (float precision) ---
float2 bicubicSampleUV_16tap(
    texture2d<half, access::sample> tex,
    float2 uv_px,
    uint2 texSize
) {
    float2 p = uv_px - 0.5f;
    int2 ip = int2(floor(p));
    float2 f = p - float2(ip);
    float2 texSizeF = float2(texSize);

    float2 rows[4];
    for (int r = 0; r < 4; r++) {
        int y = clamp(ip.y + r - 1, 0, int(texSize.y) - 1);
        float2 col[4];
        for (int c = 0; c < 4; c++) {
            int x = clamp(ip.x + c - 1, 0, int(texSize.x) - 1);
            float2 norm = (float2(x, y) + 0.5f) / texSizeF;
            col[c] = float2(tex.sample(nearestClampSampler, norm).rg);
        }
        rows[r] = catmullRom1D_uv(col[0], col[1], col[2], col[3], f.x);
    }

    return catmullRom1D_uv(rows[0], rows[1], rows[2], rows[3], f.y);
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

// --- Bicubic kernel (4-tap for Y, 16-tap for UV) ---
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
    float2 src = mapDstToSrc(dst, params);

    float srcXf = src.x;
    float srcYf = src.y;

    // --- Y 4-tap bicubic ---
    if (srcXf < 0.0f || srcXf > float(W - 1) ||
        srcYf < 0.0f || srcYf > float(H - 1)) {
        dstY.write(half(0.0), gid);
    } else {
        float yF = bicubicSampleY_4tap(
            srcY,
            float2(srcXf, srcYf),
            float2(srcY.get_width(), srcY.get_height())
        );
        dstY.write(half(yF), gid);
    }

    // --- UV 16-tap bicubic ---
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
                uint2(srcUV.get_width(), srcUV.get_height())
            );

            dstUV.write(
                half4(half(uvF.x), half(uvF.y), 0.0h, 1.0h),
                uvPos
            );
        }
    }
}

// --- Unsharp mask for Y plane (3x3 gaussian blur + unsharp) ---
kernel void unsharpY(
    texture2d<half, access::sample> srcY   [[ texture(0) ]],
    texture2d<half, access::write>  dstY   [[ texture(1) ]],
    constant float& amount                 [[ buffer(0) ]],
    uint2 gid                              [[ thread_position_in_grid ]]
) {
    uint w = dstY.get_width();
    uint h = dstY.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float center = float(srcY.sample(pixelNearest, float2(gid)).x);

    // 3x3 gaussian blur (unnormalized, sum = 16)
    // 1 2 1
    // 2 4 2
    // 1 2 1
    float sum = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float wgt;
            if (dx == 0 && dy == 0) wgt = 4.0;
            else if (dx == 0 || dy == 0) wgt = 2.0;
            else wgt = 1.0;
            float2 sampPos = float2(float(int(gid.x) + dx), float(int(gid.y) + dy));
            sum += wgt * float(srcY.sample(pixelNearest, sampPos).x);
        }
    }
    float blurred = sum / 16.0;
    float sharpened = center + amount * (center - blurred);
    dstY.write(half(clamp(sharpened, 0.0, 1.0)), gid);
}
