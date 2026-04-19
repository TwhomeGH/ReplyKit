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




// --- Bicubic sample Y ---

half bicubicSampleY_4fetch(
    texture2d<half, access::sample> tex,
    sampler s,
    float2 uv_px,      // pixel space（跟你現在一樣）
    uint2 texSize
) {
    float2 texSizeF = float2(texSize);

    // pixel -> normalized
    float2 pixel = uv_px - 0.5;
    int2 ip = int2(floor(pixel));
    float2 f = pixel - float2(ip);

    // 4 個 bilinear sample（硬體會各自做 2x2）
    float2 uv00 = (float2(ip) + float2(0.0, 0.0) + 0.5) / texSizeF;
    float2 uv10 = (float2(ip) + float2(1.0, 0.0) + 0.5) / texSizeF;
    float2 uv01 = (float2(ip) + float2(0.0, 1.0) + 0.5) / texSizeF;
    float2 uv11 = (float2(ip) + float2(1.0, 1.0) + 0.5) / texSizeF;

    half c00 = tex.sample(s, uv00).x;
    half c10 = tex.sample(s, uv10).x;
    half c01 = tex.sample(s, uv01).x;
    half c11 = tex.sample(s, uv11).x;

    // bilinear → bicubic approximation
    half col0 = mix(c00, c10, half(f.x));
    half col1 = mix(c01, c11, half(f.x));

    return mix(col0, col1, half(f.y));
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
        R = float2x2(0, -1, 1, 0);
        break;
    case 180:
        R = float2x2(-1, 0, 0, -1);
        break;
    default: // 270
        R = float2x2(0, 1, -1, 0);
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
        float2 uvDst = float2(gid) + 1.0f;
        float2 uvSrc = mapDstToSrc(uvDst, W, H, outW, outH, params.angle);

        if (uvSrc.x < 0.0f || uvSrc.x > float(W - 1) ||
            uvSrc.y < 0.0f || uvSrc.y > float(H - 1)) {

            dstUV.write(
                half4(0.5, 0.5, 0.0, 1.0),
                uvPos
            );

        } else {
            float2 uvCoord = clamp(
                uvSrc * 0.5f,
                float2(0.0f),
                float2(float(W) * 0.5f - 1.0f, float(H) * 0.5f - 1.0f)
            );

            half2 uvVal = srcUV.sample(
                linearClampSampler,
                (uvCoord + 0.5f) / float2(float(W) * 0.5f, float(H) * 0.5f)
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

       yVal = bicubicSampleY_4fetch(
        srcY,
        linearClampSampler,
        float2(srcXf, srcYf),
        uint2(srcY.get_width(), srcY.get_height())
        );

    }

    dstY.write(yVal, gid);


 
    // --- 替換原本 UV plane 的讀取 ---

    if (((gid.x & 1u) == 0u) && ((gid.y & 1u) == 0u)) {
        uint2 uvPos = uint2(gid.x >> 1, gid.y >> 1);
        float2 uvDst = float2(gid) + 1.0f;
        float2 uvSrc = mapDstToSrc(uvDst, W, H, outW, outH, params.angle);

        if (uvSrc.x < 0.0f || uvSrc.x > float(W - 1) ||
            uvSrc.y < 0.0f || uvSrc.y > float(H - 1)) {

            dstUV.write(half4(0.5, 0.5, 0.0, 1.0), uvPos);

        } else {
            float2 uvCoord = clamp(
                uvSrc * 0.5f,
                float2(0.0f),
                float2(float(W) * 0.5f - 1.0f, float(H) * 0.5f - 1.0f)
            );

            half2 uvVal = srcUV.sample(
                linearClampSampler,
                (uvCoord + 0.5f) / float2(float(W) * 0.5f, float(H) * 0.5f)
            ).rg;

            dstUV.write(
                half4(uvVal.x, uvVal.y, 0.0, 1.0),
                uvPos
            );
        }
    }

}
