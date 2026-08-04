#!/bin/zsh
#
# build-lgpl.sh — FSPlayer LGPL 构建脚本
#
# 以 LGPLv3 许可编译 FFmpeg 8，并生成 FSPlayer iOS xcframework。
# 产物为真机 (arm64) + 模拟器 (arm64) 合并的单一 xcframework。
#
# 用法:
#   ./build-lgpl.sh all        # 执行全部步骤（Step 1 ~ Step 9）
#   ./build-lgpl.sh init       # Step 1: 初始化源码仓库
#   ./build-lgpl.sh compile    # Step 2-4: 编译所有库
#   ./build-lgpl.sh lipo       # Step 5: 手动 lipo FFmpeg8 产物
#   ./build-lgpl.sh framework  # Step 6-9: 生成 Xcode 项目 → 构建 Framework → 生成 xcframework
#   ./build-lgpl.sh verify     # 验证 LGPL 许可合规性
#

set -e

# ============================================================
# 库列表定义（使用 zsh 数组，避免分词问题）
# ============================================================

# 基础依赖库（无内部依赖）
DEPS=(openssl3 opus dav1d uavs3d smb2 webp xml2)
# 字幕库（ASS 字幕渲染所需，FSPlayer 必需依赖）
SUBTITLE=(freetype fribidi harfbuzz unibreak ass)
# 蓝光库（依赖 xml2，必须在 xml2 之后编译）
BLURAY=(bluray)
# FFmpeg（依赖以上所有库）
FFMPEG_LIB=(ffmpeg8)
# 目标架构（只编译 arm64 和 arm64_simulator，不编译 x86_64_simulator）
ARCHS=(arm64 arm64_simulator)
# FFmpeg lipo 产物列表
FFMPEG_LIPO_LIBS=(libavcodec libavformat libavutil libswscale libswresample libavfilter libavdevice)

# ============================================================
# 项目路径
# ============================================================

# 脚本所在目录（项目根目录）
PROJECT_ROOT=$(DIRNAME=$(dirname "$0"); cd "$DIRNAME"; pwd)
# FFToolChain 目录
FFTOOLCHAIN_DIR="${PROJECT_ROOT}/FFToolChain"

# ============================================================
# Step 1: 初始化源码仓库
# ============================================================

function do_init() {
    echo ""
    echo "========================================"
    echo "  Step 1: 初始化源码仓库"
    echo "========================================"
    echo ""

    cd "$FFTOOLCHAIN_DIR"

    # 1.1 初始化基础依赖库
    echo "=== 初始化基础依赖库 ==="
    ./main.sh init -p ios -l "${DEPS[*]}"

    # 1.2 初始化字幕库
    echo "=== 初始化字幕库 ==="
    ./main.sh init -p ios -l "${SUBTITLE[*]}"

    # 1.3 初始化 bluray（依赖 xml2，必须先初始化 xml2）
    echo "=== 初始化 bluray ==="
    ./main.sh init -p ios -l "${BLURAY[*]}"

    # 1.4 初始化 FFmpeg 8
    echo "=== 初始化 FFmpeg 8 ==="
    ./main.sh init -p ios -l "${FFMPEG_LIB[*]}"

    echo ""
    echo "✅ Step 1 完成：所有源码仓库已初始化"
}

# ============================================================
# Step 2-4: 编译所有库
# ============================================================

function do_compile() {
    echo ""
    echo "========================================"
    echo "  Step 2-4: 编译所有库"
    echo "========================================"
    echo ""

    cd "$FFTOOLCHAIN_DIR"

    # Step 2: 编译基础依赖库
    for arch in "${ARCHS[@]}"; do
        echo "=== 编译基础依赖库 ($arch) ==="
        ./main.sh compile -p ios -a $arch -l "${DEPS[*]}"
    done

    # Step 2.5: 编译字幕库
    for arch in "${ARCHS[@]}"; do
        echo "=== 编译字幕库 ($arch) ==="
        ./main.sh compile -p ios -a $arch -l "${SUBTITLE[*]}"
    done

    # Step 3: 编译 bluray（依赖 xml2，必须在 xml2 编译完成后才能编译）
    for arch in "${ARCHS[@]}"; do
        echo "=== 编译 bluray ($arch) ==="
        ./main.sh compile -p ios -a $arch -l "${BLURAY[*]}"
    done

    # Step 4: 编译 FFmpeg 8（LGPLv3 模式）
    # arm64 必须使用 -c rebuild，确保 --enable-version3 被正确传递
    echo "=== 编译 FFmpeg 8 (arm64, rebuild) ==="
    ./main.sh compile -p ios -a arm64 -c rebuild -l "${FFMPEG_LIB[*]}"

    echo "=== 编译 FFmpeg 8 (arm64_simulator) ==="
    ./main.sh compile -p ios -a arm64_simulator -l "${FFMPEG_LIB[*]}"

    echo ""
    echo "✅ Step 2-4 完成：所有库已编译"
}

# ============================================================
# Step 5: 手动 lipo FFmpeg8 产物
# ============================================================

function do_lipo() {
    echo ""
    echo "========================================"
    echo "  Step 5: 手动 lipo FFmpeg8 产物"
    echo "========================================"
    echo ""

    # ⚠️ 不要使用 ./main.sh install 命令！
    # install 命令会下载预编译包，覆盖本地编译的 LGPLv3 产物。

    cd "$FFTOOLCHAIN_DIR"

    # 创建目录
    mkdir -p build/product/ios/universal/ffmpeg/lib
    mkdir -p build/product/ios/universal/ffmpeg/include
    mkdir -p build/product/ios/universal-simulator/ffmpeg/lib
    mkdir -p build/product/ios/universal-simulator/ffmpeg/include

    # 真机 arm64（单架构，直接 lipo）
    echo "=== Lipo FFmpeg8 (arm64) ==="
    for lib in "${FFMPEG_LIPO_LIBS[@]}"; do
        echo "  lipo $lib"
        xcrun lipo -create build/product/ios/ffmpeg-arm64/lib/${lib}.a \
            -output build/product/ios/universal/ffmpeg/lib/${lib}.a
    done

    # 模拟器 arm64（单架构，直接 lipo）
    echo "=== Lipo FFmpeg8 (arm64_simulator) ==="
    for lib in "${FFMPEG_LIPO_LIBS[@]}"; do
        echo "  lipo $lib"
        xcrun lipo -create build/product/ios/ffmpeg-arm64_simulator/lib/${lib}.a \
            -output build/product/ios/universal-simulator/ffmpeg/lib/${lib}.a
    done

    # 复制 include 和 pkgconfig
    echo "=== 复制 include 和 pkgconfig ==="
    cp -Rf build/product/ios/ffmpeg-arm64/include build/product/ios/universal/ffmpeg/
    cp -Rf build/product/ios/ffmpeg-arm64/lib/pkgconfig build/product/ios/universal/ffmpeg/lib/
    cp -Rf build/product/ios/ffmpeg-arm64_simulator/include build/product/ios/universal-simulator/ffmpeg/
    cp -Rf build/product/ios/ffmpeg-arm64_simulator/lib/pkgconfig build/product/ios/universal-simulator/ffmpeg/lib/

    # 修正 pkgconfig 路径（将 prefix 指向当前构建目录）
    echo "=== 修正 pkgconfig 路径 ==="
    BASE_DIR="$(pwd)"
    for pc in build/product/ios/universal/ffmpeg/lib/pkgconfig/*.pc; do
        sed -i '' "s|prefix=.*|prefix=${BASE_DIR}/build/product/ios/universal/ffmpeg|" "$pc"
        sed -i '' "s|libdir=.*|libdir=${BASE_DIR}/build/product/ios/universal/ffmpeg/lib|" "$pc"
        sed -i '' "s|includedir=.*|includedir=${BASE_DIR}/build/product/ios/universal/ffmpeg/include|" "$pc"
    done
    for pc in build/product/ios/universal-simulator/ffmpeg/lib/pkgconfig/*.pc; do
        sed -i '' "s|prefix=.*|prefix=${BASE_DIR}/build/product/ios/universal-simulator/ffmpeg|" "$pc"
        sed -i '' "s|libdir=.*|libdir=${BASE_DIR}/build/product/ios/universal-simulator/ffmpeg/lib|" "$pc"
        sed -i '' "s|includedir=.*|includedir=${BASE_DIR}/build/product/ios/universal-simulator/ffmpeg/include|" "$pc"
    done

    # 验证 lipo 结果
    echo ""
    echo "=== 验证 lipo 结果 ==="
    lipo -info build/product/ios/universal/ffmpeg/lib/libavcodec.a
    lipo -info build/product/ios/universal-simulator/ffmpeg/lib/libavcodec.a

    echo ""
    echo "✅ Step 5 完成：FFmpeg8 产物已 lipo"
}

# ============================================================
# Step 6-9: 生成 Xcode 项目 → 构建 Framework → 生成 xcframework
# ============================================================

function do_framework() {
    echo ""
    echo "========================================"
    echo "  Step 6-9: 生成 xcframework"
    echo "========================================"
    echo ""

    cd "$PROJECT_ROOT"

    # Step 6: 生成 Xcode 项目
    echo "=== 生成 Xcode 项目 ==="
    ./generate-proj.sh

    # Step 7: 构建 iOS Framework（真机 + 模拟器）
    echo "=== 构建 iOS Framework ==="
    cd examples/ios
    ./build-framework.sh

    # Step 8: 生成 xcframework（真机 + 模拟器合并）
    echo "=== 生成 xcframework ==="
    cd ../xcframewrok
    ./make-xcframework.sh

    echo ""
    echo "✅ Step 6-9 完成：xcframework 已生成"
    echo "   产物位置: examples/xcframewrok/FSPlayer.xcframework"
}

# ============================================================
# 验证 LGPL 许可合规性
# ============================================================

function do_verify() {
    echo ""
    echo "========================================"
    echo "  验证 LGPL 许可合规性"
    echo "========================================"
    echo ""

    cd "$FFTOOLCHAIN_DIR"

    local config_h="build/src/ios/ffmpeg8-arm64/config.h"
    local pass=0
    local fail=0

    if [[ ! -f "$config_h" ]]; then
        echo "❌ 找不到 config.h: $config_h"
        echo "   请先执行 ./build-lgpl.sh compile"
        return 1
    fi

    # 检查 FFMPEG_LICENSE
    local license=$(grep "FFMPEG_LICENSE" "$config_h" | sed 's/.*"\(.*\)".*/\1/')
    if [[ "$license" == "LGPL version 3 or later" ]]; then
        echo "✅ FFMPEG_LICENSE = \"$license\""
        pass=$((pass+1))
    else
        echo "❌ FFMPEG_LICENSE = \"$license\" (期望: \"LGPL version 3 or later\")"
        fail=$((fail+1))
    fi

    # 检查 CONFIG_GPL
    local gpl=$(grep "#define CONFIG_GPL " "$config_h" | awk '{print $3}')
    if [[ "$gpl" == "0" ]]; then
        echo "✅ CONFIG_GPL = 0 (GPL 已禁用)"
        pass=$((pass+1))
    else
        echo "❌ CONFIG_GPL = $gpl (期望: 0)"
        fail=$((fail+1))
    fi

    # 检查 CONFIG_NONFREE
    local nonfree=$(grep "#define CONFIG_NONFREE " "$config_h" | awk '{print $3}')
    if [[ "$nonfree" == "0" ]]; then
        echo "✅ CONFIG_NONFREE = 0 (nonfree 已禁用)"
        pass=$((pass+1))
    else
        echo "❌ CONFIG_NONFREE = $nonfree (期望: 0)"
        fail=$((fail+1))
    fi

    # 检查 CONFIG_VERSION3
    local version3=$(grep "#define CONFIG_VERSION3 " "$config_h" | awk '{print $3}')
    if [[ "$version3" == "1" ]]; then
        echo "✅ CONFIG_VERSION3 = 1 (LGPLv3 已启用)"
        pass=$((pass+1))
    else
        echo "❌ CONFIG_VERSION3 = $version3 (期望: 1)"
        fail=$((fail+1))
    fi

    # 检查 CONFIG_LGPLV3
    local lgplv3=$(grep "#define CONFIG_LGPLV3 " "$config_h" | awk '{print $3}')
    if [[ "$lgplv3" == "1" ]]; then
        echo "✅ CONFIG_LGPLV3 = 1 (LGPLv3 标志)"
        pass=$((pass+1))
    else
        echo "❌ CONFIG_LGPLV3 = $lgplv3 (期望: 1)"
        fail=$((fail+1))
    fi

    # 检查 CONFIG_OPENSSL
    local openssl=$(grep "#define CONFIG_OPENSSL " "$config_h" | awk '{print $3}')
    if [[ "$openssl" == "1" ]]; then
        echo "✅ CONFIG_OPENSSL = 1 (OpenSSL 已启用)"
        pass=$((pass+1))
    else
        echo "❌ CONFIG_OPENSSL = $openssl (期望: 1)"
        fail=$((fail+1))
    fi

    # 检查 libpostproc 不存在（GPL-only 库）
    echo ""
    if compgen -G 'build/product/ios/universal/ffmpeg/lib/libpostproc*' >/dev/null 2>&1; then
        echo "❌ libpostproc 存在 (GPL-only 库，LGPL 模式下不应编译)"
        fail=$((fail+1))
    else
        echo "✅ libpostproc 不存在 (GPL-only 库，LGPL 模式下正确)"
        pass=$((pass+1))
    fi

    # 检查 x264/x265 符号不存在
    if nm build/product/ios/universal/ffmpeg/lib/libavcodec.a 2>/dev/null | grep -q "ff_libx264\|ff_libx265"; then
        echo "❌ x264/x265 符号存在 (GPL 许可的编码器，LGPL 模式下应禁用)"
        fail=$((fail+1))
    else
        echo "✅ x264/x265 符号不存在 (GPL 许可的编码器，LGPL 模式下正确)"
        pass=$((pass+1))
    fi

    # 汇总
    echo ""
    echo "========================================"
    if [[ $fail -eq 0 ]]; then
        echo "✅ LGPL 许可验证通过 ($pass/$((pass+fail)))"
    else
        echo "❌ LGPL 许可验证失败 ($fail 项不通过)"
        echo "   请检查 FFmpeg 编译配置，确保使用 -c rebuild 重新编译"
    fi
    echo "========================================"
}

# ============================================================
# 用法帮助
# ============================================================

function show_usage() {
    echo ""
    echo "FSPlayer LGPL 构建脚本"
    echo ""
    echo "以 LGPLv3 许可编译 FFmpeg 8，并生成 FSPlayer iOS xcframework。"
    echo "产物为真机 (arm64) + 模拟器 (arm64) 合并的单一 xcframework。"
    echo ""
    echo "用法:"
    echo "  ./build-lgpl.sh <步骤>"
    echo ""
    echo "步骤:"
    echo "  all        执行全部步骤（init → compile → lipo → framework → verify）"
    echo "  init       Step 1: 初始化源码仓库（克隆 + 切换 commit + 应用 patch）"
    echo "  compile    Step 2-4: 编译所有库（基础依赖 → 字幕库 → bluray → FFmpeg8）"
    echo "  lipo       Step 5: 手动 lipo FFmpeg8 产物（不使用 install 命令）"
    echo "  framework  Step 6-9: 生成 Xcode 项目 → 构建 Framework → 生成 xcframework"
    echo "  verify     验证 LGPL 许可合规性"
    echo ""
    echo "示例:"
    echo "  ./build-lgpl.sh all        # 一键执行全部步骤"
    echo "  ./build-lgpl.sh init       # 只初始化源码"
    echo "  ./build-lgpl.sh compile    # 只编译库"
    echo "  ./build-lgpl.sh verify     # 只验证许可"
    echo ""
    echo "⚠️ 注意:"
    echo "  - 不要使用 ./main.sh install 命令，它会下载预编译包覆盖本地 LGPLv3 产物"
    echo "  - FFmpeg8 必须使用 -c rebuild 编译，确保 --enable-version3 被正确传递"
    echo "  - bluray 必须在 xml2 之后编译（脚本已处理依赖顺序）"
    echo ""
}

# ============================================================
# 主入口
# ============================================================

case "${1:-}" in
    all)
        do_init
        do_compile
        do_lipo
        do_framework
        do_verify
        echo ""
        echo "🎉 全部完成！xcframework 位于 examples/xcframewrok/FSPlayer.xcframework"
        ;;
    init)
        do_init
        ;;
    compile)
        do_compile
        ;;
    lipo)
        do_lipo
        ;;
    framework)
        do_framework
        ;;
    verify)
        do_verify
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
