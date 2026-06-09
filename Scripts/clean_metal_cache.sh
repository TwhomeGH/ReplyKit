#!/bin/bash
# clean_metal_cache.sh
# 
# 清除 Xcode Metal shader cache，強制重新編譯 .metal 檔案。
# 當修改 rotateNV12.metal 或其他 Metal shader 後，
# 如果 Xcode 沒有自動重新編譯，執行此腳本再 Build。

echo "🧹 清除 Metal shader cache..."

# 找出這個專案的 DerivedData 路徑
PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_NAME=$(basename "$PROJECT_DIR"/*.xcodeproj .xcodeproj 2>/dev/null || echo "liveAPP")

DD_DIR="$HOME/Library/Developer/Xcode/DerivedData"

if [ -d "$DD_DIR" ]; then
    for dir in "$DD_DIR"/"$PROJECT_NAME"-*; do
        if [ -d "$dir" ]; then
            echo "   清除: $dir/Build/Intermediates.noindex"
            rm -rf "$dir/Build/Intermediates.noindex"/*.metallib 2>/dev/null
            rm -rf "$dir/Build/Intermediates.noindex"/*.metallibsym 2>/dev/null

            # 清除 ShaderCache
            SHADER_CACHE="$dir/Build/Intermediates.noindex/ShaderCache"
            if [ -d "$SHADER_CACHE" ]; then
                echo "   清除 ShaderCache: $SHADER_CACHE"
                rm -rf "$SHADER_CACHE"
            fi
        fi
    done
fi

echo "✅ 完成。請在 Xcode 中重新 Build（⌘B）來重新編譯 Metal shader。"
