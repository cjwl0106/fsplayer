---
name: build-ios-framework
description: 一键构建遵循 LGPLv3 协议的 FSPlayer iOS xcframework（真机 arm64 + 模拟器 arm64 合并为单一 xcframework）。自动执行从源码初始化到 xcframework 生成的完整流程，并验证 LGPL 许可合规性。
user-invocable: true
---

# build-ios-framework — 构建 LGPLv3 FSPlayer iOS xcframework

一键构建遵循 **LGPL version 3** 许可的 FSPlayer iOS xcframework，产物为真机 (arm64) + 模拟器 (arm64) 合并的单一 xcframework。

## 产出

- `examples/xcframewrok/FSPlayer.xcframework` — 包含 iOS 真机 arm64 和 iOS 模拟器 arm64

## 前置条件

确保以下工具已安装：

```bash
brew install cmake ninja nasm pkg-config meson perl xcodegen
xcode-select --install
```

验证：
```bash
cmake --version && ninja --version && nasm --version && pkg-config --version && meson --version && xcodegen --version
```

## 构建流程

按以下步骤顺序执行。所有命令在项目根目录 `/Users/hik/Documents/workspace/github/fsplayer` 下运行，除非另有说明。

### Step 1: 初始化源码

进入 FFToolChain 目录，初始化所有 LGPL 兼容的依赖库和 FFmpeg 8：

```bash
cd FFToolChain

# 初始化基础依赖（不含 bluray，bluray 依赖 xml2 需要先编译 xml2）
./main.sh init -p ios -l 'openssl3 opus dav1d uavs3d smb2 webp xml2'

# 初始化 FFmpeg 8
./main.sh init -p ios -l 'ffmpeg8'
```

> ⚠️ LGPL 模式下以下库不可用（已从配置中禁用）：
> - **x264 / x265** — GPL 许可的编码器
> - **dvdread / dvdnav** — GPL 许可的 DVD 库
> - **libpostproc** — GPL-only 的后处理库

### Step 2: 编译基础依赖库

只编译 arm64（真机）和 arm64_simulator（模拟器），**不编译 x86_64_simulator**：

```bash
# 真机 arm64
./main.sh compile -p ios -a arm64 -l 'openssl3 opus dav1d uavs3d smb2 webp xml2'

# 模拟器 arm64
./main.sh compile -p ios -a arm64_simulator -l 'openssl3 opus dav1d uavs3d smb2 webp xml2'
```

### Step 3: 编译 bluray

bluray 依赖 libxml2，必须在 xml2 编译完成后才能编译：

```bash
./main.sh compile -p ios -a arm64 -l 'bluray'
./main.sh compile -p ios -a arm64_simulator -l 'bluray'
```

### Step 4: 编译 FFmpeg 8（LGPLv3 模式）

**必须使用 `-c rebuild`** 确保 `--enable-version3` 被正确传递，否则 FFmpeg 会以 LGPLv2.1 编译且 OpenSSL 无法启用：

```bash
# 真机 arm64 — rebuild 强制重新 configure
./main.sh compile -p ios -a arm64 -c rebuild -l 'ffmpeg8'

# 模拟器 arm64
./main.sh compile -p ios -a arm64_simulator -l 'ffmpeg8'
```

### Step 5: 验证 LGPLv3 许可

**此步骤不可跳过！** 检查 FFmpeg 的许可配置：

```bash
grep "CONFIG_GPL\|CONFIG_NONFREE\|CONFIG_VERSION3\|CONFIG_OPENSSL\|FFMPEG_LICENSE" FFToolChain/build/src/ios/ffmpeg8-arm64/config.h
```

期望输出：
```
#define FFMPEG_LICENSE "LGPL version 3 or later"
#define CONFIG_OPENSSL 1
#define CONFIG_GPL 0
#define CONFIG_NONFREE 0
#define CONFIG_VERSION3 1
#define CONFIG_LGPLV3 1
```

如果 `CONFIG_VERSION3` 为 0 或 `CONFIG_OPENSSL` 为 0，说明 `--enable-version3` 没被正确传递，需要重新执行 Step 4 的 rebuild。

额外验证：
```bash
# libpostproc 不应存在（GPL-only）
ls FFToolChain/build/product/ios/universal/ffmpeg/lib/libpostproc* 2>&1  # 应报 No such file

# x264/x265 符号不应存在
nm FFToolChain/build/product/ios/universal/ffmpeg/lib/libavcodec.a | grep "ff_libx264\|ff_libx265" | head -3  # 应无输出
```

### Step 6: 手动 lipo FFmpeg8 产物

**⚠️ 不要使用 `./main.sh install` 命令！** install 命令会下载预编译包覆盖本地编译的 LGPLv3 产物。

由于 FFToolChain 的 lipo 命令不支持多架构参数，需要手动执行 lipo：

```bash
cd FFToolChain

# 创建目录
mkdir -p build/product/ios/universal/ffmpeg/lib
mkdir -p build/product/ios/universal/ffmpeg/include
mkdir -p build/product/ios/universal-simulator/ffmpeg/lib
mkdir -p build/product/ios/universal-simulator/ffmpeg/include

# 真机 arm64（单架构，直接复制）
for lib in libavcodec libavformat libavutil libswscale libswresample libavfilter libavdevice; do
    xcrun lipo -create build/product/ios/ffmpeg-arm64/lib/${lib}.a -output build/product/ios/universal/ffmpeg/lib/${lib}.a
done

# 模拟器 arm64（单架构，直接复制）
for lib in libavcodec libavformat libavutil libswscale libswresample libavfilter libavdevice; do
    xcrun lipo -create build/product/ios/ffmpeg-arm64_simulator/lib/${lib}.a -output build/product/ios/universal-simulator/ffmpeg/lib/${lib}.a
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

### Step 7: 生成 Xcode 项目

回到项目根目录：

```bash
cd /Users/hik/Documents/workspace/github/fsplayer
./generate-proj.sh
```

### Step 8: 构建 iOS Framework（真机 + 模拟器）

```bash
cd examples/ios
./build-framework.sh
```

产物：
- `Release-iphoneos/FSPlayer.framework`（真机 arm64）
- `Release-iphonesimulator/FSPlayer.framework`（模拟器 arm64）

### Step 9: 生成 xcframework（真机 + 模拟器合并）

**⚠️ 不要包含 dSYM！** 包含 dSYM 会导致在其他项目中出现 "Missing path from XCFramework as defined by DebugSymbolsPath" 错误。

直接使用 `xcodebuild -create-xcframework` 不带 `-debug-symbols` 参数：

```bash
cd examples/xcframewrok
rm -rf FSPlayer.xcframework
xcodebuild -create-xcframework \
    -framework ../ios/Release-iphoneos/FSPlayer.framework \
    -framework ../ios/Release-iphonesimulator/FSPlayer.framework \
    -output FSPlayer.xcframework
```

产物：`examples/xcframewrok/FSPlayer.xcframework`

> ⚠️ 不要使用 `./make-xcframework.sh`！它默认会包含 dSYM，导致在其他项目中报错。
> 脚本已更新为不包含 dSYM，但为了确保一致性，建议直接使用上面的命令。

### Step 10: 最终验证

```bash
# 检查 xcframework 产物
ls examples/xcframewrok/FSPlayer.xcframework/

# 检查架构
lipo -info examples/ios/Release-iphoneos/FSPlayer.framework/FSPlayer      # arm64
lipo -info examples/ios/Release-iphonesimulator/FSPlayer.framework/FSPlayer  # arm64

# 检查 xcframework 包含的切片
xcodebuild -create-xcframework \
    -framework examples/ios/Release-iphoneos/FSPlayer.framework \
    -framework examples/ios/Release-iphonesimulator/FSPlayer.framework \
    -output /tmp/test.xcframework 2>&1 | head -5
```

## LGPL 许可验证清单

| 检查项 | 期望值 | 说明 |
|--------|--------|------|
| `FFMPEG_LICENSE` | "LGPL version 3 or later" | FFmpeg 许可声明 |
| `CONFIG_GPL` | 0 | GPL 已禁用 |
| `CONFIG_NONFREE` | 0 | nonfree 已禁用 |
| `CONFIG_VERSION3` | 1 | LGPLv3 已启用 |
| `CONFIG_LGPLV3` | 1 | LGPLv3 标志 |
| `CONFIG_OPENSSL` | 1 | OpenSSL 已启用（需要 version3） |
| `libpostproc` | 不存在 | GPL-only 库，LGPL 模式下不编译 |
| x264/x265 符号 | 不存在 | GPL 许可的编码器，LGPL 模式下禁用 |
| dvdread/dvdnav | 不引用 | GPL 许可的 DVD 库，已从 yml 移除 |

## 关键注意事项

1. **不要使用 `./main.sh install`** — 它会下载预编译包覆盖本地 LGPLv3 编译产物
2. **必须使用 `-c rebuild` 编译 FFmpeg8** — 确保 `--enable-version3` 被正确传递
3. **不要包含 dvdread/dvdnav** — GPL 许可，与 LGPL 不兼容
4. **不要包含 x264/x265** — GPL 许可的编码器，与 LGPL 不兼容
5. **bluray 必须在 xml2 之后编译** — bluray 依赖 libxml2
6. **只编译 arm64 和 arm64_simulator** — 不需要 x86_64_simulator
7. **lipo 需要手动执行** — FFToolChain 的 lipo 命令不支持多架构参数，每次 lipo 会删除之前的产物

## 常见问题

### Q: `CONFIG_VERSION3` 为 0

说明 `--enable-version3` 没被正确传递到 FFmpeg configure。使用 `-c rebuild` 重新编译：

```bash
./main.sh compile -p ios -a arm64 -c rebuild -l 'ffmpeg8'
```

### Q: `reuse configure` 导致许可没有更新

删除源码目录中的 `config.h`：

```bash
rm FFToolChain/build/src/ios/ffmpeg8-arm64/config.h
rm FFToolChain/build/src/ios/ffmpeg8-arm64_simulator/config.h
```

或使用 `-c rebuild`。

### Q: lipo 时找不到 `libpostproc.a`

这是正常的！`libpostproc` 是 GPL-only 的库，LGPL 模式下不会编译。

### Q: 想要完全清理重新构建

```bash
cd FFToolChain
./main.sh compile -p ios -a arm64 -c clean -l 'openssl3 opus bluray dav1d uavs3d smb2 webp xml2 ffmpeg8'
./main.sh compile -p ios -a arm64_simulator -c clean -l 'openssl3 opus bluray dav1d uavs3d smb2 webp xml2 ffmpeg8'
```

然后从 Step 2 重新开始。
