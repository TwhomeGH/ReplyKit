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


    uint rotW = (params.angle % 180 == 0) ? W : H;
    uint rotH = (params.angle % 180 == 0) ? H : W;


    // 縮放後的實際寬高
    float scaleX = float(outW) / float(rotW);
    float scaleY = float(outH) / float(rotH);
    float uniformScale = min(scaleX, scaleY);


    

    float2 dst = float2(gid.x + 0.5f, gid.y + 0.5f);

    // output center
    float2 outCenter = float2(rotW, rotH) * 0.5f;

    float2 scaledSize = float2(rotW, rotH) * uniformScale;
    float2 offset = (float2(outW, outH) - scaledSize) * 0.5f;

    float2 p = (dst - offset) / uniformScale;


    float2x2 R;

    switch(params.angle) {
    case 0:
        R = float2x2(1,0, 0,1);
        break;

    case 90:   // CCW
        R = float2x2(0,-1, 1,0);
        break;

    case 180:
        R = float2x2(-1,0, 0,-1);
        break;

    case 270:
        R = float2x2(0,1, -1,0);
        break;
    }


    float2 srcCenter = float2(W, H) * 0.5f;

    // final mapping
    float2 src = R * p;
    src += srcCenter;

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
   if (srcXf < 0.0f || srcXf > float(W - 1) ||
    srcYf < 0.0f || srcYf > float(H - 1)) {

    // 黑邊 UV（對應黑色）
    dstUV.write(
        half4(0.5, 0.5, 0.0, 1.0),
        uint2(gid.x >> 1, gid.y >> 1)
    );

} else {

    float halfW = float(W) * 0.5f;
    float halfH = float(H) * 0.5f;

    float2 uvCoord = float2(srcXf, srcYf) * 0.5f;

    uvCoord = clamp(
        uvCoord,
        float2(0.0f),
        float2(W * 0.5f - 1.0f, H * 0.5f - 1.0f)
    );

    half2 uvVal = srcUV.sample(
        linearClampSampler,
        (uvCoord + 0.5f) / float2(halfW, halfH)
    ).rg;

        dstUV.write(
            half4(uvVal.x, uvVal.y, 0.0, 1.0),
            uint2(gid.x >> 1, gid.y >> 1)
        );
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


    uint rotW = (params.angle % 180 == 0) ? W : H;
    uint rotH = (params.angle % 180 == 0) ? H : W;

    // 縮放後的實際寬高
    float scaleX = float(outW) / float(rotW);
    float scaleY = float(outH) / float(rotH);

    // 等比例縮放
    float uniformScale = min(scaleX, scaleY);

    // ❗直接用 dst space 做 center（不要再用 scaledW/H）
    float2 dst = float2(gid.x + 0.5f, gid.y + 0.5f);

    // output center
    float2 outCenter = float2(outW, outH) * 0.5f;

    // normalized screen space
    float2 scaledSize = float2(rotW, rotH) * uniformScale;
    float2 offset = (float2(outW, outH) - scaledSize) * 0.5f;

    float2 p = (dst - offset) / uniformScale;


    float2x2 R;

    switch(params.angle) {
    case 0:
        R = float2x2(1,0, 0,1);
        break;

    case 90:
        R = float2x2(0,-1, 1,0);
        break;

    case 180:
        R = float2x2(-1,0, 0,-1);
        break;

    case 270:
        R = float2x2(0,1, -1,0);
        break;
    }

    float2 srcCenter = float2(W, H) * 0.5f;

    float2 src = R * p + srcCenter;

    float srcXf = src.x;
    float srcYf = src.y;

    uint maxX = srcY.get_width();
    uint maxY = srcY.get_height();


   



    half yVal;

    if (srcXf < 0.0f || srcXf > float(W - 1) ||
    srcYf < 0.0f || srcYf > float(H - 1)) {

    yVal = half(0.0);

    } else {

       yVal = bicubicSampleY_4fetch(
        srcY,
        linearClampSampler,
        float2(srcXf / float(W), srcYf / float(H)),
        uint2(srcY.get_width(), srcY.get_height())
        );

    }

    dstY.write(yVal, gid);


 
    // --- 替換原本 UV plane 的讀取 ---

    uint2 uvPos = uint2(gid.x >> 1, gid.y >> 1);

    if (srcXf < 0.0f || srcXf > float(W - 1) ||
        srcYf < 0.0f || srcYf > float(H - 1)) {

        dstUV.write(half4(0.5, 0.5, 0.0, 1.0), uvPos);

    } else {

        float2 uvCoord = (float2(srcXf, srcYf) + 0.5f) * 0.5f;

        half2 uvVal = srcUV.sample(
            linearClampSampler,
            uvCoord / float2(W * 0.5f, H * 0.5f)
        ).rg;

        dstUV.write(
            half4(uvVal.x, uvVal.y, 0.0, 1.0),
            uvPos
        );
    }

}
