---
name: upgrade-deps
description: 检查并升级 FSPlayer 所有 LGPL 兼容依赖库的版本。自动查询上游最新版本，对比当前版本，生成报告，用户确认后自动修改配置文件和 BUILD_GUIDE.md。
user-invocable: true
---

# upgrade-deps — 升级 FSPlayer 依赖库

检查并升级 FSPlayer 所有 LGPL 兼容依赖库的版本。自动执行：查询上游最新版本 → 对比当前版本 → 生成报告 → 用户确认后自动修改配置文件和文档。

## 依赖库清单

共 14 个 LGPL 兼容的依赖库，按编译顺序分组：

| 分组 | 库名 | 说明 |
|------|------|------|
| 基础依赖 | openssl3, opus, dav1d, uavs3d, smb2, webp, xml2 | 无内部依赖 |
| 字幕库 | freetype, fribidi, harfbuzz, unibreak, ass | harfbuzz 依赖 freetype |
| 蓝光 | bluray | 依赖 xml2 |
| FFmpeg | ffmpeg8 | 依赖以上所有 |

## 执行流程

### Step 1: 扫描当前版本

读取 `FFToolChain/configs/libs/<lib>.sh` 中每个库的以下字段：

- `GIT_COMMIT` — 当前使用的 git tag/commit
- `GIT_REPO_VERSION` — 语义化版本号
- `PRE_COMPILE_TAG_*` — 预编译包 tag（判断是否已注释或与当前版本不匹配）
- `PATCH_DIR` — 是否有 patch 目录（升级需额外注意兼容性）
- `GIT_UPSTREAM` — 上游仓库 URL

### Step 2: 查询上游最新版本

对每个库使用 `git ls-remote --tags` 查询最新 tag，按语义化版本排序取最新稳定版。

**各库的查询规则：**

| 库名 | 上游仓库 | tag 过滤规则 | 当前 tag 格式 |
|------|----------|-------------|---------------|
| openssl3 | `https://github.com/openssl/openssl.git` | `openssl-3.*`，排除 alpha/beta | `openssl-3.6.3` |
| opus | `https://gitlab.xiph.org/xiph/opus.git` | `v1.*` | `v1.6.1` |
| dav1d | `https://code.videolan.org/videolan/dav1d.git` | `1.*` | `1.5.4` |
| uavs3d | `https://github.com/uavs3/uavs3d.git` | 检查最新 release tag | commit hash `1fd0491` |
| smb2 | `https://github.com/sahlberg/libsmb2.git` | `libsmb2-*` | `libsmb2-6.2` |
| webp | `https://github.com/debugly/libwebp.git` | `v1.*`（fork 仓库） | `v1.6.0` |
| xml2 | `https://github.com/GNOME/libxml2.git` | `v2.*`，排除 rc | `v2.15.3` |
| bluray | `https://code.videolan.org/videolan/libbluray.git` | `1.*` | `1.5.0` |
| freetype | `https://gitlab.freedesktop.org/freetype/freetype.git` | `VER-*` | `VER-2-14-3` |
| fribidi | `https://github.com/fribidi/fribidi.git` | `v1.*` | `v1.0.16` |
| harfbuzz | `https://github.com/harfbuzz/harfbuzz.git` | 数字版本号 `*.*.*` | `14.3.0` |
| unibreak | `https://github.com/adah1972/libunibreak.git` | `libunibreak_*` | `libunibreak_7_0` |
| ass | `https://github.com/libass/libass.git` | `0.*` | `0.17.5` |
| ffmpeg8 | `https://github.com/FFmpeg/FFmpeg.git` | `n8.*` | `n8.1.2` |

**查询命令示例：**

```bash
# GitHub 仓库
git ls-remote --tags https://github.com/openssl/openssl.git | grep -o 'refs/tags/openssl-3\.[0-9]*\.[0-9]*$' | sed 's|refs/tags/||' | sort -V | tail -1

# GitLab 仓库
git ls-remote --tags https://gitlab.xiph.org/xiph/opus.git | grep -o 'refs/tags/v[0-9.]*$' | sed 's|refs/tags/||' | sort -V | tail -1

# VideoLAN 仓库
git ls-remote --tags https://code.videolan.org/videolan/dav1d.git | grep -o 'refs/tags/[0-9.]*$' | sed 's|refs/tags/||' | sort -V | tail -1
```

**特殊情况处理：**
- **uavs3d**: 使用 commit hash 而非版本 tag，查询最新 release tag 后需确认是否对应新版本
- **webp**: 使用 debugly fork 而非上游，需查询 fork 仓库的 tag
- **harfbuzz**: tag 是纯数字版本号（如 `14.3.0`），需过滤掉非版本号 tag

### Step 3: 生成对比报告

输出格式：

```
| 库名 | 当前版本 | 最新版本 | 需升级 | PRE_COMPILE_TAG | 有 Patch |
|------|----------|----------|--------|-----------------|----------|
| openssl3 | 3.6.3 | 3.6.4 | ✅ | 已注释 | ❌ |
| opus | 1.6.1 | 1.6.1 | ❌ | 正常 | ❌ |
| dav1d | 1.5.4 | 1.5.4 | ❌ | 过期(1.5.3) | ❌ |
| bluray | 1.5.0 | 1.5.1 | ✅ | 过期(1.3.4) | ✅ |
| ffmpeg8 | 8.1.2 | 8.1.2 | ❌ | 正常 | ✅ |
```

**PRE_COMPILE_TAG 状态说明：**
- **正常**: PRE_COMPILE_TAG 版本与 GIT_REPO_VERSION 一致
- **过期**: PRE_COMPILE_TAG 版本低于 GIT_REPO_VERSION（已升级但预编译包未更新）
- **已注释**: PRE_COMPILE_TAG 已被注释掉（强制从源码编译）

### Step 4: 用户确认后自动修改

对用户确认需要升级的库，执行以下修改：

#### 4.1 修改库配置文件

修改 `FFToolChain/configs/libs/<lib>.sh`：

1. **更新 `GIT_COMMIT`** — 改为新的 git tag
2. **更新 `GIT_REPO_VERSION`** — 改为新的语义化版本号
3. **注释掉所有 `PRE_COMPILE_TAG_*`** — 在行首添加 `# `（预编译包版本不匹配，需从源码编译）

**示例（openssl3 从 3.6.3 升级到 3.6.4）：**

修改前：
```bash
export GIT_COMMIT=openssl-3.6.3
export GIT_REPO_VERSION=3.6.3
export PRE_COMPILE_TAG_IOS=openssl3-3.6.2-260407203333
```

修改后：
```bash
export GIT_COMMIT=openssl-3.6.4
export GIT_REPO_VERSION=3.6.4
# export PRE_COMPILE_TAG_IOS=openssl3-3.6.2-260407203333
```

#### 4.2 更新 BUILD_GUIDE.md 版本表

更新 `BUILD_GUIDE.md` 顶部的依赖库版本表，修改版本号和说明。

#### 4.3 检查 patch 兼容性

以下库有 PATCH_DIR，升级时需提醒用户检查 patch 是否兼容新版本：

| 库名 | PATCH_DIR | Patch 文件数 | 说明 |
|------|-----------|-------------|------|
| uavs3d | `../../patches/uavs3d` | 少量 | 需检查 |
| smb2 | `../../patches/smb2-6.2` | 少量 | 需检查 |
| bluray | `../../patches/bluray` | 3 个 | 需检查 iOS mount 适配 |
| ffmpeg8 | `../../patches/ffmpeg-n8.1.2` | 27 个 | **重大关注**：patch 目录名包含版本号，升级后需创建新目录 |

**ffmpeg8 patch 目录特殊处理：**
- 当前 patch 目录为 `patches/ffmpeg-n8.1.2`，目录名包含版本号
- 如果 FFmpeg 升级到新版本（如 8.2.0），需要：
  1. 创建新的 patch 目录 `patches/ffmpeg-n8.2.0`
  2. 从旧目录复制 patch 文件
  3. 逐个验证 patch 是否能应用到新版本
  4. 更新 `ffmpeg8.sh` 中的 `PATCH_DIR` 指向新目录

### Step 5: 升级后操作提醒

升级完成后，输出以下提醒：

```
⚠️ 升级后必须执行以下操作：

1. 重新初始化源码：
   cd FFToolChain
   ./main.sh init -p ios -l '<升级的库名>'

2. 重新编译所有升级的库（按依赖顺序）：
   # 基础依赖
   ./main.sh compile -p ios -a arm64 -l '<升级的基础依赖>'
   ./main.sh compile -p ios -a arm64_simulator -l '<升级的基础依赖>'
   
   # 字幕库
   ./main.sh compile -p ios -a arm64 -l '<升级的字幕库>'
   ./main.sh compile -p ios -a arm64_simulator -l '<升级的字幕库>'
   
   # bluray
   ./main.sh compile -p ios -a arm64 -l 'bluray'
   ./main.sh compile -p ios -a arm64_simulator -l 'bluray'
   
   # FFmpeg（必须 rebuild）
   ./main.sh compile -p ios -a arm64 -c rebuild -l 'ffmpeg8'
   ./main.sh compile -p ios -a arm64_simulator -l 'ffmpeg8'

3. 如果 FFmpeg 升级，必须使用 -c rebuild 确保 --enable-version3 被正确传递

4. 使用 /build-ios-framework 执行完整构建流程
```

## 关键注意事项

1. **PRE_COMPILE_TAG 必须注释掉** — 升级后预编译包版本不匹配，不注释会导致下载旧版本
2. **ffmpeg8 必须使用 `-c rebuild`** — 确保 `--enable-version3` 被正确传递，否则 LGPLv3 许可无效
3. **bluray patch 需要检查** — iOS mount 适配 patch 可能不兼容新版本
4. **ffmpeg8 patch 目录名包含版本号** — 升级后需创建新目录并更新 PATCH_DIR
5. **webp 使用 fork 仓库** — 不是上游官方仓库，tag 可能不同步
6. **uavs3d 使用 commit hash** — GIT_COMMIT 不是版本号，升级时需确认对应关系
7. **编译顺序很重要** — bluray 必须在 xml2 之后编译，FFmpeg 必须最后编译
8. **harfbuzz 依赖 freetype** — 如果 freetype 升级，harfbuzz 也需要重新编译
9. **ass 依赖 freetype/fribidi/harfbuzz** — 如果这些库升级，ass 也需要重新编译
