---
name: build-ios-framework
description: 一键构建遵循 LGPLv3 协议的 FSPlayer iOS xcframework（真机 arm64 + 模拟器 arm64 合并为单一 xcframework）。自动执行从源码初始化到 xcframework 生成的完整流程，并验证 LGPL 许可合规性。
user-invocable: true
---

# build-ios-framework — 构建 LGPLv3 FSPlayer iOS xcframework

一键构建遵循 **LGPL version 3** 许可的 FSPlayer iOS xcframework，产物为真机 (arm64) + 模拟器 (arm64) 合并的单一 xcframework。

## 产出

- `examples/xcframewrok/FSPlayer.xcframework` — 包含 iOS 真机 arm64 和 iOS 模拟器 arm64

## 构建流程

所有构建步骤已自动化为 [build-lgpl.sh](../../../build-lgpl.sh) 脚本：

```bash
# 一键执行全部步骤（init → compile → lipo → framework → verify）
./build-lgpl.sh all

# 也可以分步执行
./build-lgpl.sh init       # Step 1: 初始化源码仓库
./build-lgpl.sh compile    # Step 2-4: 编译所有库
./build-lgpl.sh lipo       # Step 5: 手动 lipo FFmpeg8 产物
./build-lgpl.sh framework  # Step 6-9: 生成 xcframework
./build-lgpl.sh verify     # 验证 LGPL 许可合规性
```

**手动步骤的详细说明请参照 [BUILD_GUIDE.md](../../../BUILD_GUIDE.md)**。

## 补充说明

### 生成 xcframework

`./build-lgpl.sh framework` 内部调用 `./make-xcframework.sh`，该脚本已更新为不包含 dSYM（避免在其他项目中出现 "Missing path from XCFramework as defined by DebugSymbolsPath" 错误），可以直接使用。

也可以手动执行等效命令：

```bash
cd examples/xcframewrok
rm -rf FSPlayer.xcframework
xcodebuild -create-xcframework \
    -framework ../ios/Release-iphoneos/FSPlayer.framework \
    -framework ../ios/Release-iphonesimulator/FSPlayer.framework \
    -output FSPlayer.xcframework
```

### 最终验证

`./build-lgpl.sh verify` 会自动检查 LGPL 许可合规性。如需手动验证：

```bash
# 检查 xcframework 产物
ls examples/xcframewrok/FSPlayer.xcframework/

# 检查架构
lipo -info examples/ios/Release-iphoneos/FSPlayer.framework/FSPlayer      # arm64
lipo -info examples/ios/Release-iphonesimulator/FSPlayer.framework/FSPlayer  # arm64
```

## 关键注意事项

1. **不要使用 `./main.sh install`** — 它会下载预编译包覆盖本地 LGPLv3 编译产物
2. **必须使用 `-c rebuild` 编译 FFmpeg8** — 确保 `--enable-version3` 被正确传递（`build-lgpl.sh` 已处理）
3. **不要包含 dvdread/dvdnav** — GPL 许可，与 LGPL 不兼容
4. **不要包含 x264/x265** — GPL 许可的编码器，与 LGPL 不兼容
5. **bluray 必须在 xml2 之后编译** — bluray 依赖 libxml2（`build-lgpl.sh` 已处理依赖顺序）
6. **只编译 arm64 和 arm64_simulator** — 不需要 x86_64_simulator
7. **lipo 需要手动执行** — FFToolChain 的 lipo 命令不支持多架构参数，每次 lipo 会删除之前的产物
8. **bluray 1.5.0 使用 meson 构建系统** — 从 autotools 切换到 meson，编译脚本已更新
9. **bluray 1.5.0 需要手动 patch** — 旧版 patch 不兼容，需要手动添加 bd_file_read/seek/size、bd_open_fs 和 iOS mount 适配
10. **harfbuzz 14.3.0 需要 objcpp 编译器** — meson cross file 需要添加 `objc` 和 `objcpp` binary 定义
11. **FFmpeg 编译前需要确保 universal 目录有所有库的 pkgconfig** — lipo 命令会删除之前的产物，需要手动恢复
12. **字幕库是必需依赖** — freetype、fribidi、harfbuzz、unibreak、ass 被 FSPlayer 直接链接，不是可选的

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

### Q: bluray 编译失败 - `bootstrap` 文件不存在

bluray 1.5.0 已从 autotools 切换到 meson 构建系统。编译脚本已更新为使用 `meson-compatible.sh`。

### Q: bluray 编译失败 - `DiskArbitration/DADisk.h` 文件不存在

iOS 不支持 DiskArbitration framework。需要修改 bluray 源码的 `src/meson.build`，在 iOS 上使用 `file/mount.c`（stub 实现）替代 `file/mount_darwin.c`。

### Q: harfbuzz 编译失败 - `objcpp` compiler binary not defined

需要在 meson cross file 中添加 `objc` 和 `objcpp` binary 定义：
```
[binaries]
objc = 'clang'
objcpp = 'clang++'
```

### Q: FFmpeg 编译时 openssl/bluray 被禁用

确保 `build/product/ios/universal/` 目录下有所有库的 pkgconfig 文件。lipo 命令会删除之前的产物，需要手动恢复。

### Q: 想要完全清理重新构建

```bash
cd FFToolChain
./main.sh compile -p ios -a arm64 -c clean -l 'openssl3 opus bluray dav1d uavs3d smb2 webp xml2 freetype fribidi harfbuzz unibreak ass ffmpeg8'
./main.sh compile -p ios -a arm64_simulator -c clean -l 'openssl3 opus bluray dav1d uavs3d smb2 webp xml2 freetype fribidi harfbuzz unibreak ass ffmpeg8'
```

然后从 Step 2 重新开始，或直接执行 `./build-lgpl.sh compile`。
