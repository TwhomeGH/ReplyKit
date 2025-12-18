#include <metal_stdlib>
using namespace metal;

struct Params {
    uint srcWidth;
    uint srcHeight;
    uint dstWidth;
    uint dstHeight;
    uint angle;       // 0 / 90 / 180 / 270
    
};

#define TILE_SIZE 16
#define MAX_TILE_SIZE 32
#define BORDER    1


// --- Cubic Hermite interpolation ---
half cubicHermite(half v0, half v1, half v2, half v3, half t) {
    half a0 = -0.5*v0 + 1.5*v1 - 1.5*v2 + 0.5*v3;
    half a1 = v0 - 2.5*v1 + 2.0*v2 - 0.5*v3;
    half a2 = -0.5*v0 + 0.5*v2;
    half a3 = v1;
    return ((a0*t + a1)*t + a2)*t + a3;
}


// 4-fetch bicubic approximation
half2 bicubicSampleApprox(texture2d<half, access::sample> tex,
                           sampler s,
                           float2 uv_px,
                           uint2 texSize) {

    float2 texSizeF = float2(texSize);
    float2 uv = uv_px / texSizeF; // convert pixel coords to [0,1] uv

    // 計算整數像素位置
    float2 pixel = uv * texSizeF - 0.5;
    int2 iPix = int2(floor(pixel));
    float2 f = pixel - float2(iPix);

    // sample 四個點 (2x2 bilinear fetches)
    float2 uv00 = (float2(iPix) + float2(0.0,0.0) + 0.5) / texSizeF;
    float2 uv10 = (float2(iPix) + float2(1.0,0.0) + 0.5) / texSizeF;
    float2 uv01 = (float2(iPix) + float2(0.0,1.0) + 0.5) / texSizeF;
    float2 uv11 = (float2(iPix) + float2(1.0,1.0) + 0.5) / texSizeF;

    float2 c00 = float2(tex.sample(s, uv00).rg);
    float2 c10 = float2(tex.sample(s, uv10).rg);
    float2 c01 = float2(tex.sample(s, uv01).rg);
    float2 c11 = float2(tex.sample(s, uv11).rg);

    // 先對 x 做 cubic interpolation（近似用 bilinear）：
    float2 col0 = mix(c00, c10, f.x);
    float2 col1 = mix(c01, c11, f.x);

    // 再對 y 做 cubic interpolation（近似用 bilinear）
    float2 result = mix(col0, col1, f.y);

    return half2(result);
}

// --- Bicubic sample Y ---


half bicubicSampleY(texture2d<half, access::read> tex, float2 uv, uint2 texSize) {
    int2 p = int2(floor(uv));
    half arr[4][4];
    for (int j=-1;j<=2;j++)
        for (int i=-1;i<=2;i++)
            arr[j+1][i+1] = tex.read(uint2(clamp(p+int2(i,j), int2(0,0), int2(texSize.x-1, texSize.y-1)))).x;

    half col[4];
    half fx = half(uv.x - floor(uv.x));
    half fy = half(uv.y - floor(uv.y));
    for(int j=0;j<4;j++) col[j] = cubicHermite(arr[j][0],arr[j][1],arr[j][2],arr[j][3],fx);
    return cubicHermite(col[0],col[1],col[2],col[3],fy);
}

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



inline float4 cubicWeights(float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    return float4(
        -0.5*t3 + t2 - 0.5*t,
         1.5*t3 - 2.5*t2 + 1.0,
        -1.5*t3 + 2.0*t2 + 0.5*t,
         0.5*t3 - 0.5*t2
    );
}


// 計算 threadgroup index

inline float2 getLocalUV(threadgroup half2 localUV[],
                          int2 tileOriginUV,
                          int2 coord,
                          uint tileSizeUW,
                          uint tileSizeUH)
{
    // 將 global pixel 座標轉成 tile-local 座標
    int lx = coord.x - tileOriginUV.x + BORDER;
    int ly = coord.y - tileOriginUV.y + BORDER;

    // clamp 到 tile buffer 範圍（0 ~ tileSize + 2*BORDER - 1）
    lx = clamp(lx, 0, int(tileSizeUW + 2*BORDER - 1));
    ly = clamp(ly, 0, int(tileSizeUH + 2*BORDER - 1));

    // 計算一維索引
    uint index = ly * (MAX_TILE_SIZE/2 + 2*BORDER) + lx;

    // 取值
    return float2(localUV[index]);
}







inline half2 readUVFromTile(threadgroup half2 localUV[],
                            int2 tileOriginUV,
                            int2 coord,
                            texture2d<half, access::read> srcUV,
                            uint tileW,
                            uint tileH)
{
    int lx = coord.x - tileOriginUV.x + BORDER;
    int ly = coord.y - tileOriginUV.y + BORDER;
    uint index = ly * (MAX_TILE_SIZE/2 + 2*BORDER) + lx;

    if (lx >= 0 && lx < int(tileW) + 2*BORDER &&
        ly >= 0 && ly < int(tileH) + 2*BORDER)
    {
        return localUV[index];
    } else {
        int2 cl = clamp(coord, int2(0), int2(srcUV.get_width()-1, srcUV.get_height()-1));
        return srcUV.read(uint2(cl)).rg;
    }
}





constexpr sampler linearClampSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);


// --- Main kernel ---
kernel void rotateNV12_tileBicubicUV(
    texture2d<half, access::sample> srcY   [[ texture(0) ]],
    texture2d<half, access::sample> srcUV  [[ texture(1) ]],
    texture2d<half, access::write> dstY  [[ texture(2) ]],
    texture2d<half, access::write> dstUV  [[ texture(3) ]],
    constant Params& params               [[ buffer(0) ]],
    uint2 gid                             [[ thread_position_in_grid ]],
    uint2 tid                             [[ thread_position_in_threadgroup ]],
    uint2 group_id                        [[ threadgroup_position_in_grid ]]
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

    half yVal;

    float shrinkFactor = min(scaleX, scaleY);
    half sharpenStrength = 0;

    if (shrinkFactor < 1.0) {
        // 縮小時加強
        sharpenStrength = half(clamp((1.0/shrinkFactor - 1.0) * 0.5, 0.0, 1.0));
    }


    yVal = bicubicSampleY_4fetch(
        srcY,
        linearClampSampler,
        float2(srcXf, srcYf),
        uint2(maxX, maxY)
    );




    // Gamma 校正
    float yLinear = pow(float(yVal),2.2);

    yVal = half(pow(yLinear, 1.0/2.2));
    dstY.write(yVal, gid);



    // --- UV plane ---
    // --- 替換原本 UV plane 的讀取 ---
    if ((gid.x & 1u) == 0 && (gid.y & 1u) == 0) {
        float2 uvPos = float2(srcXf*0.5f, srcYf*0.5f);

        half2 uvVal;


        uvVal = bicubicSampleApprox(srcUV, linearClampSampler,uvPos, uint2(srcUV.get_width(), srcUV.get_height()));


        uint2 uvDst = uint2(gid.x/2, gid.y/2);
        uvDst.x = min(uvDst.x, dstUV.get_width()-1);
        uvDst.y = min(uvDst.y, dstUV.get_height()-1);
        dstUV.write(half4(uvVal.x, uvVal.y, 0.0, 1.0), uvDst);
    }

}
