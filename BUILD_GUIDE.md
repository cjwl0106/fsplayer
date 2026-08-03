# FSPlayer LGPL 编译 & iOS xcframework 生成操作指南

> 本文档指导你从零开始，以 **LGPL + version3** 许可编译 FFmpeg 8，并生成 FSPlayer iOS xcframework。
> OpenSSL 使用 **3.6.3**（Apache 2.0 许可，与 LGPL 兼容）。
> MRFFToolChain 使用最新版本（`e80ccd8b`）。
> 最终产物为真机 (arm64) + 模拟器 (arm64) 合并的单一 xcframework。
> 
> **依赖库版本（2026-07-28 升级后）：**
> | 库名 | 版本 | 说明 |
> |------|------|------|
> | openssl | 3.6.3 | 安全修复，保持 3.x 系列 |
> | opus | 1.6.1 | 已是最新 |
> | dav1d | 1.5.4 | 安全修复 |
> | uavs3d | 1.2.1 | 已是最新 |
> | smb2 | 6.2 | 已是最新 |
> | webp | v1.6.0 | 已是最新 |
> | xml2 | 2.15.3 | 安全修复 |
> | bluray | 1.5.0 | **重大升级**，从 autotools 切换到 meson |
> | freetype | 2.14.3 | 已是最新 |
> | fribidi | 1.0.16 | 已是最新 |
> | harfbuzz | 14.3.0 | **重大升级**（从 12.3.2） |
> | unibreak | 7.0 | 版本升级（从 6.1） |
> | ass | 0.17.5 | 小版本升级 |
> | ffmpeg | 8.1.2 | 已是最新 |

---

## 前置条件

### 必须安装的工具

```bash
brew install cmake ninja nasm pkg-config meson perl xcodegen
xcode-select --install
```

### 确认环境

```bash
cmake --version
ninja --version
nasm --version
pkg-config --version
meson --version
xcodegen --version
```

---

## 整体流程概览

```
Step 1: 初始化（克隆源码仓库）
  ↓
Step 2: 编译基础依赖库（OpenSSL、opus、dav1d 等）
  ↓
Step 2.5: 编译字幕库（freetype、fribidi、harfbuzz、unibreak、ass）
  ↓
Step 3: 编译 bluray（依赖 xml2）
  ↓
Step 4: 编译 FFmpeg 8（LGPLv3 模式，rebuild）
  ↓
Step 5: 验证 LGPL 许可
  ↓
Step 6: 手动 lipo FFmpeg8 产物
  ↓
Step 7: 生成 Xcode 项目
  ↓
Step 8: 构建 iOS Framework
  ↓
Step 9: 生成 xcframework（真机 + 模拟器合并）
```

---

## Step 1: 初始化源码仓库

进入 FFToolChain 目录：

```bash
cd FFToolChain
```

### 1.1 初始化基础依赖库

```bash
./main.sh init -p ios -l 'openssl3 opus dav1d uavs3d smb2 webp xml2'
```

### 1.3 初始化字幕库

字幕库是 FSPlayer 的必需依赖（用于 ASS 字幕渲染），不是可选的：

```bash
./main.sh init -p ios -l 'freetype fribidi harfbuzz unibreak ass'
```

### 1.4 初始化 bluray

```bash
./main.sh init -p ios -l 'bluray'
```

> ⚠️ bluray 依赖 libxml2，必须先初始化 xml2。此处分开初始化是为了确保依赖顺序正确。

### 1.5 初始化 FFmpeg 8

```bash
./main.sh init -p ios -l 'ffmpeg8'
```

> ⚠️ LGPL 模式下以下库不可用（已从配置中禁用）：
> - **x264 / x265** — GPL 许可的编码器
> - **dvdread / dvdnav** — GPL 许可的 DVD 库

---

## Step 2: 编译基础依赖库

只编译 **arm64**（真机）和 **arm64_simulator**（模拟器），不编译 x86_64_simulator：

```bash
# 真机 arm64
./main.sh compile -p ios -a arm64 -l 'openssl3 opus dav1d uavs3d smb2 webp xml2'

# 模拟器 arm64
./main.sh compile -p ios -a arm64_simulator -l 'openssl3 opus dav1d uavs3d smb2 webp xml2'
```

### Step 2.5: 编译字幕库

字幕库是 FSPlayer 的必需依赖（用于 ASS 字幕渲染），不是可选的：

```bash
# 真机 arm64
./main.sh compile -p ios -a arm64 -l 'freetype fribidi harfbuzz unibreak ass'

# 模拟器 arm64
./main.sh compile -p ios -a arm64_simulator -l 'freetype fribidi harfbuzz unibreak ass'
```

> ⚠️ harfbuzz 14.3.0 需要 objcpp 编译器，meson cross file 需要添加 `objc` 和 `objcpp` binary 定义。

---

## Step 3: 编译 bluray

bluray 依赖 libxml2，必须在 xml2 编译完成后才能编译：

```bash
./main.sh compile -p ios -a arm64 -l 'bluray'
./main.sh compile -p ios -a arm64_simulator -l 'bluray'
```

---

## Step 4: 编译 FFmpeg 8（LGPLv3 模式）

### 4.1 ⚠️ 必须使用 rebuild（重要！）

如果之前编译过 FFmpeg（特别是 GPL/nonfree 模式），**必须清理**旧的 `config.h`，
否则脚本会跳过重新配置，继续使用旧的 GPL 配置。同时 rebuild 确保 `--enable-version3` 被正确传递：

```bash
./main.sh compile -p ios -a arm64 -c rebuild -l 'ffmpeg8'
./main.sh compile -p ios -a arm64_simulator -l 'ffmpeg8'
```

> `-c rebuild` = clean + build，会先执行 `git clean -xdf` 清除源码目录中的所有生成文件，
> 然后重新 configure 和编译。

### 4.2 验证许可

编译完成后，检查 FFmpeg 的许可配置：

```bash
grep "CONFIG_GPL\|CONFIG_NONFREE\|CONFIG_VERSION3\|CONFIG_OPENSSL\|FFMPEG_LICENSE" build/src/ios/ffmpeg8-arm64/config.h
```

期望输出：
```
#define FFMPEG_LICENSE "LGPL version 3 or later"
#define CONFIG_OPENSSL 1          ← OpenSSL 已启用 ✅
#define CONFIG_GPL 0              ← GPL 禁用 ✅
#define CONFIG_NONFREE 0          ← nonfree 禁用 ✅
#define CONFIG_VERSION3 1         ← version3 启用 ✅
#define CONFIG_LGPLV3 1           ← LGPLv3 启用 ✅
```

如果 `CONFIG_VERSION3` 为 0 或 `CONFIG_OPENSSL` 为 0，说明 `--enable-version3` 没被正确传递，
需要重新执行 Step 4.1 的 rebuild。

---

## Step 5: 手动 lipo FFmpeg8 产物

**⚠️ 不要使用 `./main.sh install` 命令！** install 命令会下载预编译包，覆盖本地编译的 LGPLv3 产物。
需要手动执行 lipo 来合并多架构产物：

```bash
cd FFToolChain

# 创建目录
mkdir -p build/product/ios/universal/ffmpeg/lib
mkdir -p build/product/ios/universal/ffmpeg/include
mkdir -p build/product/ios/universal-simulator/ffmpeg/lib
mkdir -p build/product/ios/universal-simulator/ffmpeg/include

# 真机 arm64（单架构，直接复制）
for lib in libavcodec libavformat libavutil libswscale libswresample libavfilter libavdevice; do
    xcrun lipo -create build/product/ios/ffmpeg-arm64/lib/${lib}.a \
        -output build/product/ios/universal/ffmpeg/lib/${lib}.a
done

# 模拟器 arm64（单架构，直接复制）
for lib in libavcodec libavformat libavutil libswscale libswresample libavfilter libavdevice; do
    xcrun lipo -create build/product/ios/ffmpeg-arm64_simulator/lib/${lib}.a \
        -output build/product/ios/universal-simulator/ffmpeg/lib/${lib}.a
done

# 复制 include 和 pkgconfig
cp -Rf build/product/ios/ffmpeg-arm64/include build/product/ios/universal/ffmpeg/
cp -Rf build/product/ios/ffmpeg-arm64/lib/pkgconfig build/product/ios/universal/ffmpeg/lib/
cp -Rf build/product/ios/ffmpeg-arm64_simulator/include build/product/ios/universal-simulator/ffmpeg/
cp -Rf build/product/ios/ffmpeg-arm64_simulator/lib/pkgconfig build/product/ios/universal-simulator/ffmpeg/lib/

# 修正 pkgconfig 路径
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
```

验证 lipo 结果：

```bash
lipo -info build/product/ios/universal/ffmpeg/lib/libavcodec.a        # arm64
lipo -info build/product/ios/universal-simulator/ffmpeg/lib/libavcodec.a  # arm64
```

---

## Step 6: 生成 Xcode 项目

回到项目根目录：

```bash
cd /Users/hik/Documents/workspace/github/fsplayer
./generate-proj.sh
```

---

## Step 7: 构建 iOS Framework

```bash
cd examples/ios
./build-framework.sh
```

产物：
- `Release-iphoneos/FSPlayer.framework`（真机 arm64）
- `Release-iphonesimulator/FSPlayer.framework`（模拟器 arm64）

---

## Step 8: 生成 xcframework（真机 + 模拟器合并）

将真机和模拟器 Framework 合并为单一 xcframework：

```bash
cd examples/xcframewrok
./make-xcframework.sh
```

产物：`xcframewrok/FSPlayer.xcframework`，包含 iOS 真机 arm64 和 iOS 模拟器 arm64。

> 💡 `make-xcframework.sh` 默认会尝试合并所有平台。如果 macOS/tvOS 的 Framework 不存在，
> 脚本会自动跳过这些平台，只合并 iOS 的真机和模拟器。

---

## 快速一键脚本

```bash
#!/bin/zsh
set -e

cd FFToolChain

DEPS="openssl3 opus dav1d uavs3d smb2 webp xml2"
SUBTITLE="freetype fribidi harfbuzz unibreak ass"
BLURAY="bluray"
FFMPEG_LIB="ffmpeg8"
ARCHS="arm64 arm64_simulator"

# Step 1: 初始化
echo "=== Init deps ==="
./main.sh init -p ios -l "$DEPS"
echo "=== Init subtitle ==="
./main.sh init -p ios -l "$SUBTITLE"
echo "=== Init bluray ==="
./main.sh init -p ios -l "$BLURAY"
echo "=== Init ffmpeg8 ==="
./main.sh init -p ios -l "$FFMPEG_LIB"

# Step 2: 编译基础依赖
for arch in $ARCHS; do
    echo "=== Compile deps for $arch ==="
    ./main.sh compile -p ios -a $arch -l "$DEPS"
done

# Step 2.5: 编译字幕库
for arch in $ARCHS; do
    echo "=== Compile subtitle for $arch ==="
    ./main.sh compile -p ios -a $arch -l "$SUBTITLE"
done

# Step 3: 编译 bluray
for arch in $ARCHS; do
    echo "=== Compile bluray for $arch ==="
    ./main.sh compile -p ios -a $arch -l "$BLURAY"
done

# Step 4: 编译 FFmpeg（rebuild 确保 LGPLv3）
echo "=== Rebuild FFmpeg for arm64 ==="
./main.sh compile -p ios -a arm64 -c rebuild -l "$FFMPEG_LIB"
echo "=== Compile FFmpeg for arm64_simulator ==="
./main.sh compile -p ios -a arm64_simulator -l "$FFMPEG_LIB"

# Step 5: 验证许可
echo "=== Verify LGPL license ==="
grep "CONFIG_GPL\|CONFIG_NONFREE\|CONFIG_VERSION3\|CONFIG_OPENSSL\|FFMPEG_LICENSE" build/src/ios/ffmpeg8-arm64/config.h

# Step 6: 手动 lipo FFmpeg8
echo "=== Lipo FFmpeg8 ==="
mkdir -p build/product/ios/universal/ffmpeg/lib build/product/ios/universal/ffmpeg/include
mkdir -p build/product/ios/universal-simulator/ffmpeg/lib build/product/ios/universal-simulator/ffmpeg/include

for lib in libavcodec libavformat libavutil libswscale libswresample libavfilter libavdevice; do
    xcrun lipo -create build/product/ios/ffmpeg-arm64/lib/${lib}.a -output build/product/ios/universal/ffmpeg/lib/${lib}.a
    xcrun lipo -create build/product/ios/ffmpeg-arm64_simulator/lib/${lib}.a -output build/product/ios/universal-simulator/ffmpeg/lib/${lib}.a
done

cp -Rf build/product/ios/ffmpeg-arm64/include build/product/ios/universal/ffmpeg/
cp -Rf build/product/ios/ffmpeg-arm64/lib/pkgconfig build/product/ios/universal/ffmpeg/lib/
cp -Rf build/product/ios/ffmpeg-arm64_simulator/include build/product/ios/universal-simulator/ffmpeg/
cp -Rf build/product/ios/ffmpeg-arm64_simulator/lib/pkgconfig build/product/ios/universal-simulator/ffmpeg/lib/

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

# Step 7-8: 生成项目和 Framework
cd ..
./generate-proj.sh

cd examples/ios && ./build-framework.sh

# Step 9: xcframework
cd ../xcframewrok && ./make-xcframework.sh

echo "✅ 全部完成！xcframework 位于 examples/xcframewrok/FSPlayer.xcframework"
```

---

## 许可验证清单

| 检查项 | 期望值 | 说明 |
|--------|--------|------|
| `FFMPEG_LICENSE` | "LGPL version 3 or later" | FFmpeg 许可声明 |
| `CONFIG_GPL` | 0 | GPL 已禁用 |
| `CONFIG_NONFREE` | 0 | nonfree 已禁用 |
| `CONFIG_VERSION3` | 1 | LGPLv3 已启用 |
| `CONFIG_LGPLV3` | 1 | LGPLv3 标志 |
| `CONFIG_OPENSSL` | 1 | OpenSSL 已启用（需要 version3） |
| OpenSSL 版本 | 3.6.3 | Apache 2.0 许可 |
| `libpostproc` | 不存在 | GPL-only 库，LGPL 模式下不编译 |
| x264 / x265 | 不启用 | GPL 许可的编码器，LGPL 模式下禁用 |
| DVD 支持 | 不存在 | libdvdread/libdvdnav 是 GPL 许可 |

验证命令：

```bash
grep -E "CONFIG_GPL|CONFIG_NONFREE|CONFIG_VERSION3|CONFIG_OPENSSL|FFMPEG_LICENSE" build/src/ios/ffmpeg8-arm64/config.h
ls build/product/ios/universal/ffmpeg/lib/libpostproc* 2>&1  # 应报 No such file
nm build/product/ios/universal/ffmpeg/lib/libavcodec.a | grep "ff_libx264\|ff_libx265" | head -3  # 应无输出
```

---

## 最终产物

| 产物 | 路径 | 架构 |
|------|------|------|
| iOS xcframework | `examples/xcframewrok/FSPlayer.xcframework` | 真机 arm64 + 模拟器 arm64 |

xcframework 内部结构：
```
FSPlayer.xcframework/
  Info.plist
  ios-arm64/
    FSPlayer.framework/   ← 真机 arm64
  ios-arm64_x86_64-simulator/
    FSPlayer.framework/   ← 模拟器 arm64（可能包含 x86_64）
```

---

## 常见问题

### Q: 编译 FFmpeg 时报错找不到 OpenSSL

确保 OpenSSL 已先编译，且 pkg-config 能找到它：

```bash
export PKG_CONFIG_PATH="$(pwd)/build/product/ios/universal/openssl/lib/pkgconfig"
pkg-config --libs openssl
```

### Q: `reuse configure` 导致许可没有更新

删除源码目录中的 `config.h`：

```bash
rm build/src/ios/ffmpeg8-arm64/config.h
rm build/src/ios/ffmpeg8-arm64_simulator/config.h
```

或使用 `-c rebuild` 重新编译。

### Q: `CONFIG_VERSION3` 为 0 或 `CONFIG_OPENSSL` 为 0

说明 `--enable-version3` 没被正确传递到 FFmpeg configure。使用 `-c rebuild` 重新编译：

```bash
./main.sh compile -p ios -a arm64 -c rebuild -l 'ffmpeg8'
```

### Q: lipo 时找不到 `libpostproc.a`

这是正常的！`libpostproc` 是 GPL-only 的库，LGPL 模式下不会编译。
`LIPO_LIBS` 配置已移除 `libpostproc`。

### Q: `./main.sh install` 覆盖了本地编译产物

**不要使用 `install` 命令！** 它会下载预编译包覆盖本地 LGPLv3 编译产物。
请使用手动 lipo 方式（见 Step 5）来生成 universal 库。

### Q: 新版本 MRFFToolChain 中 x264/x265 被自动检测启用

新版本的上游 `auto-detect-third-libs.sh` 会自动检测 x264/x265 并添加 `--enable-gpl`。
LGPL 修改已将这部分替换为禁用提示。如果你看到 configure 输出中出现了 `--enable-gpl --enable-libx264`，
说明修改没有正确应用，需要重新检查 `auto-detect-third-libs.sh`。
