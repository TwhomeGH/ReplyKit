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


    float scaleX = float(W)  / float(outW);
    float scaleY = float(H) / float(outH);

    // 等比例縮放
    float uniformScale = min(scaleX, scaleY);

    float offsetX = (outW - W / uniformScale) * 0.5f;
    float offsetY = (outH - H / uniformScale) * 0.5f;

    float srcXf = (float(gid.x) - offsetX) * uniformScale;
    float srcYf = (float(gid.y) - offsetY) * uniformScale;


   switch(params.angle) {
    case 0:  /* 保持 srcXf/srcYf，不再覆蓋 */ break;
    case 90: {
        float tmpX = srcXf;
        srcXf = float(W-1) - srcYf;
        srcYf = tmpX;
        break;
    }
    case 180: {
        srcXf = float(W-1) - srcXf;
        srcYf = float(H-1) - srcYf;
        break;
    }
    case 270: {
        float tmpY = srcYf;
        srcYf = float(H-1) - srcXf;
        srcXf = tmpY;
        break;
    }
    default: break;
}




    // --- Y bilinear ---
    half yVal = srcY.sample(
        linearClampSampler,
        float2(srcXf / params.srcWidth, srcYf / params.srcHeight)
    ).x;

    dstY.write(yVal, gid);

    // --- UV bilinear ---
    if ((gid.x & 1u) == 0 && (gid.y & 1u) == 0) {
        float2 uvPos = float2(srcXf * 0.5f, srcYf * 0.5f);
        half2 uvVal = half2(
            srcUV.sample(
                linearClampSampler,
                uvPos / float2(params.srcWidth * 0.5f,
                               params.srcHeight * 0.5f)
            ).rg
        );

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

    if (gid.x >= dstW || gid.y >= dstH) return;


    uint maxX = srcY.get_width();
    uint maxY = srcY.get_height();


    // --- dst -> src mapping 與 bicubic/linear 插值 ---
    float scaleX = float(W)/float(dstW);
    float scaleY = float(H)/float(dstH);
    float srcXf = 0.0, srcYf = 0.0;

    switch(params.angle) {
        case 0:  srcXf = float(gid.x)*scaleX; srcYf = float(gid.y)*scaleY; break;
        case 90: srcXf = float(W-1) - float(gid.y)*(float(W)/dstH); srcYf = float(gid.x)*(float(H)/dstW); break;
        case 180: srcXf = float(W-1) - float(gid.x)*scaleX; srcYf = float(H-1) - float(gid.y)*scaleY; break;
        case 270: srcXf = float(gid.y)*(float(W)/dstH); srcYf = float(H-1) - float(gid.x)*(float(H)/dstW); break;
        default: srcXf = float(gid.x)*scaleX; srcYf = float(gid.y)*scaleY; break;
    }

    half yVal = bicubicSampleY_4fetch(
                                     srcY,
                                     linearClampSampler,
                                     float2(srcXf, srcYf),
                                     uint2(maxX, maxY)
                                     );






    dstY.write(yVal, gid);


    // --- UV plane ---
    // --- 替換原本 UV plane 的讀取 ---
    if ((gid.x & 1u) == 0 && (gid.y & 1u) == 0) {
        float2 uvPos = float2(srcXf*0.5f, srcYf*0.5f);



        half2 uvVal = half2(
            srcUV.sample(linearClampSampler,
                uvPos / float2(srcUV.get_width(), srcUV.get_height())
            ).rg
        );

        uint2 uvDst = uint2(gid.x/2, gid.y/2);
        uvDst.x = min(uvDst.x, dstUV.get_width()-1);
        uvDst.y = min(uvDst.y, dstUV.get_height()-1);
        dstUV.write(half4(uvVal.x, uvVal.y, 0.0, 1.0), uvDst);
    }

}
