#include <metal_stdlib>
using namespace metal;

struct Params {
    uint srcWidth;
    uint srcHeight;
    uint dstWidth;
    uint dstHeight;
    uint angle;       // 0 / 90 / 180 / 270
    uint useBicubic;  // 0 = bilinear, 1 = bicubic
    uint tileWidth;
    uint tileHeight;

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

// --- Bicubic sample UV ---
half2 bicubicSampleUV(
    texture2d<half, access::read> tex,
    float2 uv_px,
    uint2 texSize
) {
    // 對齊 pixel center（原本隱含，現在顯式）
    uv_px -= 0.5;

    int2 p = int2(floor(uv_px));
    float2 f = uv_px - float2(p);

    float2 arr[4][4];

    for (int j = -1; j <= 2; j++) {
        for (int i = -1; i <= 2; i++) {
            int2 c = clamp(
                p + int2(i, j),
                int2(0),
                int2(texSize) - 1
            );
            arr[j + 1][i + 1] = float2(tex.read(uint2(c)).rg);
        }
    }

    float2 col[4];
    for (int j = 0; j < 4; j++) {
        col[j].x = cubicHermite(arr[j][0].x, arr[j][1].x, arr[j][2].x, arr[j][3].x, f.x);
        col[j].y = cubicHermite(arr[j][0].y, arr[j][1].y, arr[j][2].y, arr[j][3].y, f.x);
    }

    float2 result;
    result.x = cubicHermite(col[0].x, col[1].x, col[2].x, col[3].x, f.y);
    result.y = cubicHermite(col[0].y, col[1].y, col[2].y, col[3].y, f.y);

    return half2(result);
}

// --- Read Y from tile ---
inline half readYFromTile(threadgroup half localY[][MAX_TILE_SIZE+2*BORDER],
                           int2 tileOrigin,
                           int2 coord,
                           texture2d<half, access::read> srcY,
                           half sharpenStrength,
                          uint tileW,
                          uint tileH
                          )
{
    int lx = coord.x - tileOrigin.x + BORDER;
    int ly = coord.y - tileOrigin.y + BORDER;

    half val;


    // 如果在 tile 範圍內
    if(lx>=0 && lx< int(tileW)+2*BORDER && ly>=0 && ly<int(tileH)+2*BORDER) {
        val = localY[ly][lx];

        // 簡單 3x3 銳化
        if(lx>0 && ly>0 && lx< int(tileW) +2*BORDER-1 && ly< int(tileH)+2*BORDER-1 && sharpenStrength>0.0) {
            half neighborAvg = 0.25*(localY[ly-1][lx] + localY[ly+1][lx] + localY[ly][lx-1] + localY[ly][lx+1]);
            half sharpen = val + sharpenStrength * (val - neighborAvg);
            val = half(clamp(float(sharpen), 0.0, 1.0));
        }
    } else {
        // 超出 tile，用原本讀取方式
        int2 cl = clamp(coord, int2(0), int2(srcY.get_width()-1, srcY.get_height()-1));
        val = srcY.read(uint2(cl)).x;
    }

    return val;
}


// 計算一維 index 的 helper
inline uint localIndex(uint x, uint y, uint stride) {
    return y * stride + x;
}

inline half readTileY(threadgroup half localY[],
                      int2 tileOrigin,
                      int2 coord,
                      texture2d<half, access::read> srcY,
                      int tileSizeW,
                      int tileSizeH,
                      half sharpenStrength,
                      int maxX,
                      int maxY)
{
    int lx = coord.x - tileOrigin.x + BORDER;
    int ly = coord.y - tileOrigin.y + BORDER;
    int index = ly * (MAX_TILE_SIZE + 2*BORDER) + lx;

    // 在 tile 內
    if(lx >= 0 && lx < tileSizeW + 2*BORDER && ly >= 0 && ly < tileSizeH + 2*BORDER)
    {
        half val = localY[index];
        if(lx>0 && ly>0 && lx<tileSizeW + 2*BORDER-1 && ly<tileSizeH + 2*BORDER-1 && sharpenStrength>0.0)
        {
            half neighborAvg = 0.25 * (
                localY[(ly-1)*(MAX_TILE_SIZE+2*BORDER)+lx] +
                localY[(ly+1)*(MAX_TILE_SIZE+2*BORDER)+lx] +
                localY[ly*(MAX_TILE_SIZE+2*BORDER)+(lx-1)] +
                localY[ly*(MAX_TILE_SIZE+2*BORDER)+(lx+1)]
            );
            val = half(clamp(float(val + sharpenStrength*(val-neighborAvg)),0.0,1.0));
        }
        return val;
    }
    else
    {
        int2 cl = clamp(coord, int2(0,0), int2(maxX-1, maxY-1));
        return srcY.read(uint2(cl)).x;
    }
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


// --- Main kernel ---
kernel void rotateNV12_tileBicubicUV(
    texture2d<half, access::read> srcY   [[ texture(0) ]],
    texture2d<half, access::read> srcUV  [[ texture(1) ]],
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

    // --- Y tile (一維 threadgroup buffer) ---
    threadgroup half localY[(MAX_TILE_SIZE + 2*BORDER)*(MAX_TILE_SIZE + 2*BORDER)];

    uint tileSizeW = params.tileWidth;
    uint tileSizeH = params.tileHeight;

    uint maxX = srcY.get_width();
    uint maxY = srcY.get_height();
    tileSizeW = min(tileSizeW, maxX - group_id.x * tileSizeW + 1);
    tileSizeH = min(tileSizeH, maxY - group_id.y * tileSizeH + 1);

    int2 tileOrigin = int2(group_id.x * tileSizeW - BORDER, group_id.y * tileSizeH - BORDER);

    // --- 填充 threadgroup buffer ---
    for (uint j = tid.y; j < tileSizeH + 2*BORDER; j += params.tileHeight) {
        for (uint i = tid.x; i < tileSizeW + 2*BORDER; i += params.tileWidth) {
            int2 coord = tileOrigin + int2(i, j);               // 計算 global 座標
            coord.x = clamp(coord.x, 0, int(maxX - 1));
            coord.y = clamp(coord.y, 0, int(maxY - 1));

            // 一維 index 計算
            uint index = j * (MAX_TILE_SIZE + 2*BORDER) + i;
            localY[index] = srcY.read(uint2(coord)).x;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

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

    if (params.useBicubic != 0) {
        yVal = bicubicSampleY(srcY, float2(srcXf, srcYf), uint2(maxX, maxY));
    } else {
        int2 p0 = int2(floor(float2(srcXf, srcYf)));
        int2 p1 = p0 + int2(1,0);
        int2 p2 = p0 + int2(0,1);
        int2 p3 = p0 + int2(1,1);
        int2 texMax = int2(maxX-1, maxY-1);
        p0 = clamp(p0, int2(0), texMax);
        p1 = clamp(p1, int2(0), texMax);
        p2 = clamp(p2, int2(0), texMax);
        p3 = clamp(p3, int2(0), texMax);

//        float2 f = float2(srcXf, srcYf) - float2(p0);
//
//
//        half c0 = readTileY(localY, tileOrigin, p0, srcY, tileSizeW, tileSizeH, sharpenStrength, maxX, maxY);
//        half c1 = readTileY(localY, tileOrigin, p1, srcY, tileSizeW, tileSizeH, sharpenStrength, maxX, maxY);
//        half c2 = readTileY(localY, tileOrigin, p2, srcY, tileSizeW, tileSizeH, sharpenStrength, maxX, maxY);
//        half c3 = readTileY(localY, tileOrigin, p3, srcY, tileSizeW, tileSizeH, sharpenStrength, maxX, maxY);

        // --- NEAREST for Y ---

        int2 p = int2(round(srcXf), round(srcYf));
        p = clamp(p, int2(0), int2(maxX-1, maxY-1));

        // 縮小比例 < 1.0 使用 bicubic
        if (shrinkFactor < 1.0) {
            yVal = bicubicSampleY(srcY, float2(srcXf, srcYf), uint2(maxX, maxY));
        } else {

            yVal = readTileY(localY, tileOrigin, p, srcY, tileSizeW, tileSizeH, sharpenStrength, maxX, maxY);
        }

    }

    // Gamma 校正
    float yLinear = pow(float(yVal),2.2);

    yVal = half(pow(yLinear, 1.0/2.2));
    dstY.write(yVal, gid);

    // UV plane 原邏輯保持不變
    // --- UV tile (一維 threadgroup buffer) ---
    threadgroup half2 localUV[(MAX_TILE_SIZE/2 + 2*BORDER) * (MAX_TILE_SIZE/2 + 2*BORDER)];

    // 計算 UV tile 尺寸（因為是 4:2:0，每 2x2 Y 對應 1 UV）
    uint tileSizeUW = (tileSizeW + 1) / 2;
    uint tileSizeUH = (tileSizeH + 1) / 2;

    int2 tileOriginUV = int2(group_id.x * tileSizeUW - BORDER, group_id.y * tileSizeUH - BORDER);

    // 填充 threadgroup buffer
    for (uint j = tid.y; j < tileSizeUH + 2*BORDER; j += max(1u, params.tileHeight/2)) {
        for (uint i = tid.x; i < tileSizeUW + 2*BORDER; i += max(1u, params.tileWidth/2)) {
            int2 coordUV = tileOriginUV + int2(i,j);
            coordUV.x = clamp(coordUV.x, 0, int(srcUV.get_width() - 1));
            coordUV.y = clamp(coordUV.y, 0, int(srcUV.get_height() - 1));

            uint index = j * (MAX_TILE_SIZE/2 + 2*BORDER) + i;
            localUV[index] = srcUV.read(uint2(coordUV)).rg;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);



    // --- UV plane ---
    // --- 替換原本 UV plane 的讀取 ---
    if ((gid.x & 1u) == 0 && (gid.y & 1u) == 0) {
        float2 uvPos = float2(srcXf*0.5f, srcYf*0.5f);
        half2 uvVal;

//        if (params.useBicubic != 0) {
//            uvVal = bicubicSampleUV(srcUV, uvPos, uint2(srcUV.get_width(), srcUV.get_height()));
//        } else {
//            int2 u00 = int2(floor(uvPos));
//            int2 u10 = u00 + int2(1,0);
//            int2 u01 = u00 + int2(0,1);
//            int2 u11 = u00 + int2(1,1);
//            int2 uMax = int2(srcUV.get_width()-1, srcUV.get_height()-1);
//            u00 = clamp(u00, int2(0), uMax);
//            u10 = clamp(u10, int2(0), uMax);
//            u01 = clamp(u01, int2(0), uMax);
//            u11 = clamp(u11, int2(0), uMax);
//
//            float2 f = uvPos - float2(u00);
//
//            half2 c00 = readUVFromTile(localUV, tileOriginUV, u00, srcUV, tileSizeUW, tileSizeUH);
//            half2 c10 = readUVFromTile(localUV, tileOriginUV, u10, srcUV, tileSizeUW, tileSizeUH);
//            half2 c01 = readUVFromTile(localUV, tileOriginUV, u01, srcUV, tileSizeUW, tileSizeUH);
//            half2 c11 = readUVFromTile(localUV, tileOriginUV, u11, srcUV, tileSizeUW, tileSizeUH);
//            
//            uvVal = half2(
//                mix(mix(c00.x,c10.x,half(f.x)), mix(c01.x,c11.x,half(f.x)), half(f.y)),
//                mix(mix(c00.y,c10.y,half(f.x)), mix(c01.y,c11.y,half(f.x)), half(f.y))
//            );
//        }

        // 無論 params.useBicubic 或縮小比例，都使用 bicubic
        uvVal = bicubicSampleUV(srcUV, uvPos, uint2(srcUV.get_width(), srcUV.get_height()));

        

        uint2 uvDst = uint2(gid.x/2, gid.y/2);
        uvDst.x = min(uvDst.x, dstUV.get_width()-1);
        uvDst.y = min(uvDst.y, dstUV.get_height()-1);
        dstUV.write(half4(uvVal.x, uvVal.y, 0.0, 1.0), uvDst);
    }

}
