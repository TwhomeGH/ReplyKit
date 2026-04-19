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

    float scaleX = float(outW) / float(rotW);
    float scaleY = float(outH) / float(rotH);
    float uniformScale = min(scaleX, scaleY);





    // 縮放後的實際寬高
    float scaledW = rotW * uniformScale;
    float scaledH = rotH * uniformScale;



    // 計算置中偏移量
    float offsetX = (outW - scaledW) * 0.5f;
    float offsetY = (outH - scaledH) * 0.5f;

    float srcXf = (float(gid.x) + 0.5f - offsetX) / uniformScale;
    float srcYf = ((float(gid.y) + 0.5f - offsetY) / uniformScale)
             - 0.5f * (rotH - H);

    switch(params.angle) {
    case 0: break;

    case 90: { // 🔁 改成逆時針
        float tmpX = srcXf;
        float tmpY = srcYf;

        srcXf = (float(H) - 1.0f) - tmpY;
        srcYf = tmpX;

        break;
    }

    case 180: {
        srcXf = (float(W) - 1.0f) - srcXf;
        srcYf = (float(H) - 1.0f) - srcYf;
        break;
    }

   case 270: { // ✅ 順時針 270°
        float tmpX = srcXf;
        float tmpY = srcYf;

        srcXf = (float(H) - 1.0f) - tmpY;
        srcYf = tmpX;

        break;
    }
}



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

    float scaleX = float(outW) / float(rotW);
    float scaleY = float(outH) / float(rotH);

    // 等比例縮放
    float uniformScale = max(scaleX, scaleY);

    // 縮放後的實際寬高
    float scaledW = rotW * uniformScale;
    float scaledH = rotH * uniformScale;


    // 計算置中偏移量
    float offsetX = (outW - scaledW) * 0.5f;
    float offsetY = (outH - scaledH) * 0.5f;

    float srcXf = (float(gid.x) + 0.5f - offsetX) / uniformScale;
    float srcYf = ((float(gid.y) + 0.5f - offsetY) / uniformScale)
             - 0.5f * (rotH - H);





    switch(params.angle) {
    case 0: break;

    case 90: { // 🔁 改成逆時針
        float tmpX = srcXf;
        float tmpY = srcYf;

        srcXf = (float(H) - 1.0f) - tmpY;
        srcYf = tmpX;

        break;
    }

    case 180: {
        srcXf = (float(W) - 1.0f) - srcXf;
        srcYf = (float(H) - 1.0f) - srcYf;
        break;
    }

    case 270: { // ✅ 順時針 270°
        float tmpX = srcXf;
        float tmpY = srcYf;

        srcXf = (float(H) - 1.0f) - tmpY;
        srcYf = tmpX;

        break;
    }
}


    uint maxX = srcY.get_width();
    uint maxY = srcY.get_height();


   



    half yVal;

    if (srcXf < 0.0f || srcXf > float(W - 1) ||
        srcYf < 0.0f || srcYf > float(H - 1)) {

        // 黑邊
        yVal = half(0.0);

    } else {

        yVal = bicubicSampleY_4fetch(
            srcY,
            linearClampSampler,
            float2(srcXf / float(W), srcYf / float(H)),
            uint2(maxX, maxY)
        );
    }

    dstY.write(yVal, gid);


    // --- UV plane ---
    // --- 替換原本 UV plane 的讀取 ---
    if (srcXf < 0.0f || srcXf > float(W - 1) ||
    srcYf < 0.0f || srcYf > float(H - 1)) {

    dstUV.write(
        half4(0.5, 0.5, 0.0, 1.0),
        uint2(gid.x/2, gid.y/2)
    );

    } else {

        float halfW = float(rotW) * 0.5f;
        float halfH = float(rotH) * 0.5f;

        float2 uvCoord = float2(srcXf, srcYf) * 0.5f;

        // clamp 改成 rot space
        uvCoord = clamp(
            uvCoord,
            float2(0.0f),
            float2(halfW - 1.0f, halfH - 1.0f)
        );

        half2 uvVal = srcUV.sample(
            linearClampSampler,
            (uvCoord + 0.5f) / float2(halfW, halfH)
        ).rg;


        uint2 uvDst = uint2(gid.x/2, gid.y/2);
        uvDst.x = min(uvDst.x, dstUV.get_width()-1);
        uvDst.y = min(uvDst.y, dstUV.get_height()-1);

        dstUV.write(
            half4(uvVal.x, uvVal.y, 0.0, 1.0),
            uvDst
        );
    }

}
