#include <metal_stdlib>
using namespace metal;

struct Params {
    uint srcWidth;
    uint srcHeight;
    uint dstWidth;
    uint dstHeight;
    uint angle;       // 0 / 90 / 180 / 270
    uint useBicubic;  // 0 = bilinear, 1 = bicubic
    uint tileHeight;
    uint tileWidth;

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
half2 bicubicSampleUV(texture2d<half, access::read> tex, float2 uv, uint2 texSize) {
    int2 p = int2(floor(uv));
    half2 arr[4][4];
    for(int j=-1;j<=2;j++)
        for(int i=-1;i<=2;i++)
            arr[j+1][i+1] = tex.read(uint2(clamp(p+int2(i,j), int2(0,0), int2(texSize.x-1, texSize.y-1)))).rg;

    half2 col[4];
    half fx = half(uv.x - floor(uv.x));
    half fy = half(uv.y - floor(uv.y));
    for(int j=0;j<4;j++) {
        col[j].x = cubicHermite(arr[j][0].x, arr[j][1].x, arr[j][2].x, arr[j][3].x, fx);
        col[j].y = cubicHermite(arr[j][0].y, arr[j][1].y, arr[j][2].y, arr[j][3].y, fx);
    }
    half2 result;
    result.x = cubicHermite(col[0].x,col[1].x,col[2].x,col[3].x, fy);
    result.y = cubicHermite(col[0].y,col[1].y,col[2].y,col[3].y, fy);
    return result;
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


// --- Main kernel ---
kernel void rotateNV12_tileBicubicUV(
    texture2d<half, access::read> srcY   [[ texture(0) ]],
    texture2d<half, access::read> srcUV  [[ texture(1) ]],
    texture2d<half, access::write> dstY  [[ texture(2) ]],
    texture2d<half, access::write> dstUV  [[ texture(3) ]],
    //texture2d<half, access::write> dstV  [[ texture(4) ]],
    constant Params& params               [[ buffer(0) ]],
    uint2 gid                             [[ thread_position_in_grid ]],
    uint2 tid                             [[ thread_position_in_threadgroup ]],
    uint2 group_id                        [[ threadgroup_position_in_grid ]]
) {
    uint W=params.srcWidth,H=params.srcHeight;

    uint dstW=params.dstWidth,dstH=params.dstHeight;
    if(gid.x>=dstW||gid.y>=dstH) return;


    // --- Y tile ---
    threadgroup half localY[MAX_TILE_SIZE+2*BORDER][
        MAX_TILE_SIZE+2*BORDER];

    uint tileSizeW = params.tileWidth;
    uint tileSizeH = params.tileHeight;


    int2 tileOrigin=int2(group_id.x* tileSizeW-BORDER, group_id.y* tileSizeH-BORDER);

    for(int j=tid.y;j< int(tileSizeH) +2*BORDER;j+= int( tileSizeH ) )

        for(int i=tid.x;i< int(tileSizeW) +2*BORDER;i+= int(tileSizeW) ){
            int2 lc=tileOrigin+int2(i,j);
            lc.x=clamp(lc.x,0,int(srcY.get_width()-1));
            lc.y=clamp(lc.y,0,int(srcY.get_height()-1));
            localY[j][i]=srcY.read(uint2(lc)).x;
        }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // --- dst -> src mapping with scaling ---
    float scaleX = float(W) / float(dstW);
    float scaleY = float(H) / float(dstH);

    // 對於 90/270，要交叉使用：
    // gid.x -> srcY 使用 scaleY_for90 = H / dstW
    // gid.y -> srcX 使用 scaleX_for90 = W / dstH


    // --- dst -> src mapping ---
    float srcXf=0.0f,srcYf=0.0f;
    switch(params.angle){
        case 0:
            srcXf=float(gid.x) * scaleX;
            srcYf=float(gid.y) * scaleY;
            break;
        case 90:
            // gid.y maps -> srcX (reversed), gid.x maps -> srcY


            srcXf=float(W - 1) - float(gid.y) * ( float(W) / dstH);
            srcYf=float(gid.x) * ( float(H) / float(dstW) );

            break;
        case 180:
            srcXf=float(W - 1) - float(gid.x) * scaleY;
            srcYf=float(H - 1) - float(gid.y) * scaleY;
            break;
        case 270:

            // gid.y maps -> srcX (not reversed), gid.x maps -> srcY (reversed)

            srcXf=float(gid.y) * ( float(W) / float (dstH) ) ;
            srcYf=float(H - 1) - float(gid.x) * ( float(H) / float (dstW) );

            break;
        default:
            srcXf=float(gid.x) * scaleX;
            srcYf=float(gid.y) * scaleY;
            break;
    }

    // --- Y plane ---
    half yVal;

    // 計算縮小比例 (原圖 / 目標)

    float shrinkFactor = min(scaleX, scaleY);

    // 根據縮小比例動態調整銳化強度
    // shrinkFactor 越大（縮小越多），強度越高；限制在 0~1
    half sharpenStrength = half(clamp((shrinkFactor - 1.0) * 0.5, 0.0, 1.0));


    if(params.useBicubic!=0) yVal=bicubicSampleY(srcY,float2(srcXf,srcYf),uint2(srcY.get_width(),srcY.get_height()));
    else{
        int2 p0=int2(floor(float2(srcXf,srcYf))),p1=p0+int2(1,0),p2=p0+int2(0,1),p3=p0+int2(1,1);
        int2 texMax=int2(srcY.get_width()-1,srcY.get_height()-1);
        p0=clamp(p0,int2(0),texMax); p1=clamp(p1,int2(0),texMax); p2=clamp(p2,int2(0),texMax); p3=clamp(p3,int2(0),texMax);
        float2 f=float2(srcXf,srcYf)-float2(p0);

        half c0=readYFromTile(localY,tileOrigin,p0,srcY,sharpenStrength,params.tileWidth,params.tileHeight), c1=readYFromTile(localY,tileOrigin,p1,srcY,sharpenStrength,params.tileWidth,params.tileHeight);
        half c2=readYFromTile(localY,tileOrigin,p2,srcY,sharpenStrength,params.tileWidth,params.tileHeight), c3=readYFromTile(localY,tileOrigin,p3,srcY,sharpenStrength,params.tileWidth,params.tileHeight);
        yVal=mix(mix(c0,c1,half(f.x)),mix(c2,c3,half(f.x)),half(f.y));
    }

    // ----- Gamma 校正 -----
    // gamma → linear
    float yLinear = pow(float(yVal), 2.2);

    // linear → gamma
    yVal = half(pow(yLinear, 1.0/2.2));


    // 計算銳化


    dstY.write(yVal,gid);


    // --- UV plane ---
    if ((gid.x & 1u) == 0 && (gid.y & 1u) == 0) {
        float2 uvPos = float2(srcXf * 0.5f, srcYf * 0.5f);
        half2 uvVal;
        if (params.useBicubic != 0) {
            uvVal = bicubicSampleUV(srcUV, uvPos, uint2(srcUV.get_width(), srcUV.get_height()));
        } else {
            // bilinear fallback
            int2 u00 = int2(floor(uvPos));
            int2 u10 = u00 + int2(1, 0);
            int2 u01 = u00 + int2(0, 1);
            int2 u11 = u00 + int2(1, 1);
            int2 uMax = int2(srcUV.get_width() - 1, srcUV.get_height() - 1);
            u00 = clamp(u00, int2(0), uMax);
            u10 = clamp(u10, int2(0), uMax);
            u01 = clamp(u01, int2(0), uMax);
            u11 = clamp(u11, int2(0), uMax);
            float2 f = uvPos - float2(u00);
            half2 c00 = srcUV.read(uint2(u00)).rg;
            half2 c10 = srcUV.read(uint2(u10)).rg;
            half2 c01 = srcUV.read(uint2(u01)).rg;
            half2 c11 = srcUV.read(uint2(u11)).rg;
            uvVal = half2(
                mix(mix(c00.x, c10.x, half(f.x)), mix(c01.x, c11.x, half(f.x)), half(f.y)),
                mix(mix(c00.y, c10.y, half(f.x)), mix(c01.y, c11.y, half(f.x)), half(f.y))
            );
        }

        uint2 uvDst = uint2(gid.x / 2, gid.y / 2);

        uvDst.x = min(uvDst.x, dstUV.get_width() - 1);
        uvDst.y = min(uvDst.y, dstUV.get_height() - 1);

        dstUV.write(half4(uvVal.x, uvVal.y, 0.0, 1.0), uvDst);


    }
}
