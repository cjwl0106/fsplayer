/*
 * ff_ffplaye_options.h
 *
 * Copyright (c) 2015 Bilibili
 * Copyright (c) 2015 Zhang Rui <bbcallen@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FSPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef FFPLAY__FF_FFPLAY_OPTIONS_H
#define FFPLAY__FF_FFPLAY_OPTIONS_H

/*
 * ============================================================================
 * 播放器选项定义（Player Options）
 * ============================================================================
 *
 * 本文件定义了所有可通过 setPlayerOptionIntValue/Value:forKey: 设置的播放器参数。
 * 这些参数通过 FFmpeg 的 AVOption 系统自动映射到 FFPlayer 结构体的对应字段。
 *
 * OC 端使用示例：
 *   [player setPlayerOptionIntValue:5 forKey:@"framedrop"];
 *   [player setPlayerOptionIntValue:0 forKey:@"packet-buffering"];
 *
 * 宏说明：
 *   OPTION_OFFSET(x)   → 计算 FFPlayer 结构体中字段 x 的字节偏移量
 *                        用于 AVOption 运行时直接读写结构体字段
 *   OPTION_INT(d,min,max)    → 整型选项，默认值 d，范围 [min, max]
 *   OPTION_INT64(d,min,max)  → 64位整型选项
 *   OPTION_DOUBLE(d,min,max) → 浮点型选项
 *   OPTION_STR(d)            → 字符串选项
 *   OPTION_CONST(d)          → 常量值（配合 .unit 字段使用，如 overlay-format 的枚举值）
 * ============================================================================
 */

#define OPTION_OFFSET(x) offsetof(FFPlayer, x)
#define OPTION_INT(default__, min__, max__) \
    .type = AV_OPT_TYPE_INT, \
    { .i64 = default__ }, \
    .min = min__, \
    .max = max__, \
    .flags = AV_OPT_FLAG_DECODING_PARAM
#define OPTION_INT64(default__, min__, max__) \
    .type = AV_OPT_TYPE_INT64, \
    { .i64 = default__ }, \
    .min = min__, \
    .max = max__, \
    .flags = AV_OPT_FLAG_DECODING_PARAM
#define OPTION_DOUBLE(default__, min__, max__) \
    .type = AV_OPT_TYPE_DOUBLE, \
    { .dbl = default__ }, \
    .min = min__, \
    .max = max__, \
    .flags = AV_OPT_FLAG_DECODING_PARAM
#define OPTION_CONST(default__) \
    .type = AV_OPT_TYPE_CONST, \
    { .i64 = default__ }, \
    .min = INT_MIN, \
    .max = INT_MAX, \
    .flags = AV_OPT_FLAG_DECODING_PARAM

#define OPTION_STR(default__) \
    .type = AV_OPT_TYPE_STRING, \
    { .str = default__ }, \
    .min = 0, \
    .max = 0, \
    .flags = AV_OPT_FLAG_DECODING_PARAM

static const AVOption ffp_context_options[] = {
    /*
     * =====================================================================
     * 一、基础流控制（对应 ffplay 命令行参数 -an/-vn/-sn）
     * =====================================================================
     */

    // 禁用音频流。设为 1 后只解码视频，不处理音频。
    // 对应 ffmpeg 命令行 -an。纯视频监控场景可设为 1。
    { "an",                             "disable audio stream",
        OPTION_OFFSET(audio_disable),   OPTION_INT(0, 0, 1) },

    // 禁用视频流。设为 1 后只解码音频，不处理视频。
    // 对应 ffmpeg 命令行 -vn。纯音频播放场景可设为 1。
    { "vn",                             "disable video stream",
        OPTION_OFFSET(video_disable),   OPTION_INT(0, 0, 1) },

    // 禁用字幕流。设为 1 后跳过所有字幕轨道。
    // 对应 ffmpeg 命令行 -sn。RTSP 监控场景建议设为 1，节省解析开销。
    { "sn",                             "disable subtitle stream",
        OPTION_OFFSET(subtitle_disable),OPTION_INT(0, 0, 1) },
    // FFP_MERGE: sn, ast, vst, sst
    // TODO: ss

    // 禁用图形显示。设为 1 后跳过视频渲染，仅做解码。
    // 纯音频播放时 FSPlayer 内部会自动设置此值为 1。
    { "nodisp",                         "disable graphical display",
        OPTION_OFFSET(display_disable), OPTION_INT(0, 0, 1) },

    /*
     * =====================================================================
     * 二、播放行为控制
     * =====================================================================
     */

    // 起播音量。范围 0~100，默认 100（最大音量）。
    { "volume",                         "set startup volume 0=min 100=max",
        OPTION_OFFSET(startup_volume),   OPTION_INT(100, 0, 100) },

    // 非标准兼容优化。默认 1（ff_ffplay_def.h:648）。
    // 设为 1 时，在 decoder_init 中设置 avctx->flags2 |= AV_CODEC_FLAG2_FAST
    // （ff_ffplay.c:3247-3248），跳过一些标准兼容性检查以换取解码速度。
    // 注意：AVOption 声明的默认值是 0，但 ffp_reset_internal 中实际初始化为 1。
    { "fast",                           "non spec compliant optimizations",
        OPTION_OFFSET(fast),            OPTION_INT(0, 0, 1) },

    // 循环播放次数。默认 1（播放一次），INT_MAX 表示无限循环。
    { "loop",                           "set number of times the playback shall be looped",
        OPTION_OFFSET(loop),            OPTION_INT(1, INT_MIN, INT_MAX) },

    /*
     * =====================================================================
     * 三、缓冲与丢帧控制（RTSP 低延迟的核心参数）
     * =====================================================================
     */

    // 无限缓冲区。三态逻辑：
    //   -1 = 自动模式（默认）：由 is_realtime() 判断，RTSP/RTP/SDP 流自动设为 1
    //    0 = 关闭：read_thread 在队列满时会暂停等待（点播场景适用）
    //    1 = 开启：read_thread 永不暂停，持续读取网络数据
    // RTSP 必须保持 infbuf=1（自动），否则 socket 缓冲区溢出会导致断连。
    // 延迟控制依赖 framedrop 而非暂停 read_thread。
    { "infbuf",                         "don't limit the input buffer size (useful with realtime streams)",
        OPTION_OFFSET(infinite_buffer), OPTION_INT(0, 0, 1) },

    // 丢帧策略。控制视频帧丢弃的激进程度：
    //   -1 = 自动模式：仅当视频不是主时钟源时丢帧（如音频主时钟场景）
    //    0 = 关闭丢帧（默认）
    //  1~120 = 强制丢帧模式：数值为连续丢帧上限
    //
    // 丢帧分两个阶段：
    //   1) 早期丢帧（解码器）：帧 PTS 落后于主时钟 → 丢弃，连续丢 N 帧后强制放行 1 帧（反饥饿）
    //   2) 晚期丢帧（渲染器）：当前时间已超过帧应显示时刻 → 跳过，直接 retry 下一帧
    // RTSP 低延迟推荐设为 5：最多连续丢 5 帧后强制显示 1 帧，保证画面不长时间静止。
    { "framedrop",                      "drop frames when cpu is too slow",
        OPTION_OFFSET(framedrop),       OPTION_INT(0, -1, 120) },

    // 起播时 seek 到指定位置（微秒）。默认 0 从头播放。
    // RTSP 实时流应设为 0，避免 open 后多余的 seek 操作。
    { "seek-at-start",                  "set offset of player should be seeked",
        OPTION_OFFSET(seek_at_start),       OPTION_INT64(0, 0, INT_MAX) },

    // 是否在渲染时叠加字幕纹理。默认 1。
    //   1 = 调用 ff_sub_get_texture() 获取字幕纹理，叠加到视频帧上显示
    //   0 = 跳过字幕渲染（video_image_display2 中不调用 ff_sub_get_texture）
    // 需要 GPU 上下文支持，iOS 上若 GPU 初始化失败会自动设为 0。
    // 纯音频播放时 FSPlayer 内部也会设为 0。
    { "subtitle_mix",                   "mix subtitle images use gpu",
        OPTION_OFFSET(subtitle_mix),        OPTION_INT(1, 0, 1) },
    // FFP_MERGE: window_title

    /*
     * =====================================================================
     * 四、滤镜
     * =====================================================================
     */
#if CONFIG_AUDIO_AVFILTER
    // 音频滤镜图。值为 filtergraph 字符串，如 "atempo=1.5"。
    // 播放器内部使用 atempo 滤镜实现变速播放。
    { "af",                             "audio filters",
        OPTION_OFFSET(afilters),        OPTION_STR(NULL) },
#endif
#if CONFIG_VIDEO_AVFILTER
    // 视频滤镜 0。值为 filtergraph 字符串。
    { "vf0",                            "video filters 0",
        OPTION_OFFSET(vfilter0),        OPTION_STR(NULL) },
#endif

    // RDFT（频谱可视化）刷新间隔，毫秒。仅在 showmode 为可视化模式时生效。
    { "rdftspeed",                      "rdft speed, in msecs",
        OPTION_OFFSET(rdftspeed),       OPTION_INT(0, 0, INT_MAX) },

    /*
     * =====================================================================
     * 五、流信息探测（首帧加载速度的关键参数）
     * =====================================================================
     */

    // 是否调用 avformat_find_stream_info() 分析流参数。默认 1。
    //   1 = 调用 avformat_find_stream_info(ic, opts)，读取并解码部分数据来填充
    //       codec、分辨率、帧率等缺失信息（ff_ffplay.c:3643-3666）
    //   0 = 跳过分析，直接使用容器头中已有的信息
    //
    // 注意：设为 0 时部分录制视频可能因信息不足而出错。
    // RTSP 场景 SDP 已提供流信息，但配合 probesize/analyzeduration 限制探测量更安全。
    { "find_stream_info",               "read and decode the streams to fill missing information with heuristics" ,
        OPTION_OFFSET(find_stream_info),    OPTION_INT(1, 0, 1) },

    // extended options in ff_ffplay.c

    /*
     * =====================================================================
     * 六、帧率与渲染控制
     * =====================================================================
     */

    // 最大渲染帧率。超过此帧率的帧会被丢弃。
    //   -1 = 不限制
    //    0 = 不限制（与 -1 等效）
    //  1~121 = 上限帧率
    // 默认 31。RTSP 摄像头建议设为摄像头实际帧率（如 25 或 30）。
    { "max-fps",                        "drop frames in video whose fps is greater than max-fps",
        OPTION_OFFSET(max_fps),         OPTION_INT(31, -1, 121) },

    /*
     * =====================================================================
     * 七、渲染像素格式（overlay-format）
     * =====================================================================
     */
#ifdef __APPLE__
    // Apple 平台默认使用 GLES2 渲染（OpenGL ES 2.0 纹理）
    { "overlay-format",                 "fourcc of overlay format",
        OPTION_OFFSET(overlay_format),  OPTION_INT(SDL_FCC__GLES2, INT_MIN, INT_MAX),
        .unit = "overlay-format" },
#else
    // 其他平台默认使用 RV32（RGB 32位软件渲染）
    { "overlay-format",                 "fourcc of overlay format",
        OPTION_OFFSET(overlay_format),  OPTION_INT(SDL_FCC_RV32, INT_MIN, INT_MAX),
        .unit = "overlay-format" },
#endif
    // 以下为 overlay-format 的可选常量值，通过 .unit = "overlay-format" 关联
    { "fcc-_es2",                       "", 0, OPTION_CONST(SDL_FCC__GLES2), .unit = "overlay-format" },     // OpenGL ES 2.0
    { "fcc-i420",                       "", 0, OPTION_CONST(SDL_FCC_I420), .unit = "overlay-format" },       // YUV 4:2:0 平面
    { "fcc-j420",                       "", 0, OPTION_CONST(SDL_FCC_J420), .unit = "overlay-format" },       // YUV 4:2:0 JPEG 范围
    { "fcc-yv12",                       "", 0, OPTION_CONST(SDL_FCC_YV12), .unit = "overlay-format" },       // YV12 (YUV 反转顺序)
    { "fcc-nv12",                       "", 0, OPTION_CONST(SDL_FCC_NV12), .unit = "overlay-format" },       // NV12 (Y + UV 交错)
    { "fcc-bgra",                       "", 0, OPTION_CONST(SDL_FCC_BGRA), .unit = "overlay-format" },       // BGRA 8:8:8:8
    { "fcc-bgr0",                       "", 0, OPTION_CONST(SDL_FCC_BGR0), .unit = "overlay-format" },       // BGR0 (alpha 忽略)
    { "fcc-argb",                       "", 0, OPTION_CONST(SDL_FCC_ARGB), .unit = "overlay-format" },       // ARGB 8:8:8:8
    { "fcc-0rgb",                       "", 0, OPTION_CONST(SDL_FCC_0RGB), .unit = "overlay-format" },       // XRGB (alpha 忽略)
    { "fcc-uyvy",                       "", 0, OPTION_CONST(SDL_FCC_UYVY), .unit = "overlay-format" },       // UYVY 4:2:2 打包
    { "fcc-yuv2",                       "", 0, OPTION_CONST(SDL_FCC_YUV2), .unit = "overlay-format" },       // YUY2 4:2:2 打包
    { "fcc-rv16",                       "", 0, OPTION_CONST(SDL_FCC_RV16), .unit = "overlay-format" },       // RGB 565
    { "fcc-rv24",                       "", 0, OPTION_CONST(SDL_FCC_RV24), .unit = "overlay-format" },       // RGB 888
    { "fcc-rv32",                       "", 0, OPTION_CONST(SDL_FCC_RV32), .unit = "overlay-format" },       // RGB 8888 (软件渲染默认)

    /*
     * =====================================================================
     * 八、播放生命周期
     * =====================================================================
     */

    // prepare 完成后是否自动开始播放。默认 1。
    // 设为 0 时 prepare 完成后处于暂停状态，需手动调用 play。
    { "start-on-prepared",                  "automatically start playing on prepared",
        OPTION_OFFSET(start_on_prepared),   OPTION_INT(1, 0, 1) },

    /*
     * =====================================================================
     * 九、图像队列（直接影响延迟）
     * =====================================================================
     */

    // 图像帧队列最大长度。范围 3~16，默认 3。
    // 每多 1 帧 ≈ 33ms 额外延迟（以 30fps 计）。
    // RTSP 低延迟场景建议保持最小值 3，减少缓冲延迟。
    { "video-pictq-size",                   "max picture queue frame count",
        OPTION_OFFSET(pictq_size),          OPTION_INT(VIDEO_PICTURE_QUEUE_SIZE_DEFAULT,
                                                       VIDEO_PICTURE_QUEUE_SIZE_MIN,
                                                       VIDEO_PICTURE_QUEUE_SIZE_MAX) },

    /*
     * =====================================================================
     * 十、缓冲水位线（仅在 packet-buffering=1 时生效）
     * =====================================================================
     *
     * 播放器将缓冲看作"水箱"：
     *   网络 → [水箱] → 播放画面
     * 水位线控制水箱蓄多少水才开始/恢复供水。
     *
     * 注意：packet-buffering=0 时这三个参数不起作用（缓冲管理被跳过）。
     * 注意：infbuf=1 时 read_thread 永不暂停，缓冲水位线只影响 buffering 事件通知。
     */

    // 最大缓冲大小（字节）。默认 0 表示自动决策。
    // 自动决策公式：bit_rate * MAX_PACKETS_CACHE_DURATION(10秒) + audio_delay
    // 仅当 infbuf=0 时真正限制 read_thread 暂停；infbuf=1 时无实际限制效果。
    { "max-buffer-size",                    "max buffer size (500MB) should be pre-read,support auto decision",
        OPTION_OFFSET(dcc.max_buffer_size), OPTION_INT(0, 0, 524288000 ) },

    // 最少缓冲帧数。默认 50000（点播），最小 2。
    // 缓冲的包数量达到此阈值后，认为缓冲"足够"，停止预读。
    { "min-frames",                         "minimal frames to stop pre-reading",
        OPTION_OFFSET(dcc.min_frames),      OPTION_INT(DEFAULT_MIN_FRAMES, MIN_MIN_FRAMES, MAX_MIN_FRAMES) },

    // 第一次缓冲的水位线：首次播放时，缓冲到这么多毫秒的数据就开始播放。
    // 默认 100ms。压低此值可加快首帧显示。
    { "first-high-water-mark-ms",           "first chance to wakeup read_thread",
        OPTION_OFFSET(dcc.first_high_water_mark_in_ms),
        OPTION_INT(DEFAULT_FIRST_HIGH_WATER_MARK_IN_MS,
                   DEFAULT_FIRST_HIGH_WATER_MARK_IN_MS,
                   DEFAULT_LAST_HIGH_WATER_MARK_IN_MS) },

    // 第二次缓冲的水位线：播放中卡顿后，缓冲到这么多毫秒的数据后恢复播放。
    // 默认 200ms。
    { "next-high-water-mark-ms",            "second chance to wakeup read_thread",
        OPTION_OFFSET(dcc.next_high_water_mark_in_ms),
        OPTION_INT(DEFAULT_NEXT_HIGH_WATER_MARK_IN_MS,
                   DEFAULT_FIRST_HIGH_WATER_MARK_IN_MS,
                   DEFAULT_LAST_HIGH_WATER_MARK_IN_MS) },

    // 最后一次缓冲的水位线：如果前两次都没满足，最后尝试这个更低的水位线。
    // 默认 500ms。
    { "last-high-water-mark-ms",            "last chance to wakeup read_thread",
        OPTION_OFFSET(dcc.last_high_water_mark_in_ms),
        OPTION_INT(DEFAULT_LAST_HIGH_WATER_MARK_IN_MS,
                   DEFAULT_FIRST_HIGH_WATER_MARK_IN_MS,
                   DEFAULT_LAST_HIGH_WATER_MARK_IN_MS) },

    /*
     * =====================================================================
     * 十一、包缓冲与同步
     * =====================================================================
     */

    // 包级缓冲开关。默认 1。
    //   1 = 启用缓冲管理：播放前等待缓冲充足，卡顿后暂停等待缓冲恢复
    //   0 = 关闭缓冲管理：解码线程直接取数据，不等待缓冲判断
    //
    // 关闭后效果：
    //   - ffp_toggle_buffering() 直接 return（不触发 BUFFERING_START/END 通知）
    //   - packet_queue_get_or_buffering() 直接调用 packet_queue_get() 不检查缓冲
    //   - 三个水位线参数（first/next/last-high-water-mark-ms）不再生效
    //
    // 注意：packet-buffering 和 infbuf 是独立的两个维度。
    //   packet-buffering=0 只跳过缓冲通知/等待，不影响 read_thread 的暂停逻辑。
    //   infbuf=1 控制 read_thread 永不暂停，packet-buffering=0 控制解码侧不等待缓冲。
    // RTSP 低延迟推荐设为 0。
    { "packet-buffering",                   "pause output until enough packets have been read after stalling",
        OPTION_OFFSET(packet_buffering),    OPTION_INT(1, 0, 1) },

    // 音视频起始时间同步。默认 1。
    //   1 = 音频 callback 在 video 首帧解码完成前返回 -1（静音），等待视频就绪
    //       （ff_ffplay.c:2523-2534），最多等 2 秒，超时后强制开始
    //   0 = 音频不等视频，各自独立起播
    // 纯视频流或无音频流时此参数无实际影响。
    { "sync-av-start",                      "synchronise a/v start time",
        OPTION_OFFSET(sync_av_start),       OPTION_INT(1, 0, 1) },

    // 强制指定输入格式。值为 ffmpeg 格式名（如 "rtsp"、"flv"、"mp4"）。
    // 设为 NULL 时自动探测。通常不需要手动设置。
    { "iformat",                            "force format",
        OPTION_OFFSET(iformat_name),        OPTION_STR(NULL) },

    // 是否返回播放器真实时间（不经调整）。默认 0。
    //   0 = get_current_position 返回 pos - start_diff（调整后的播放位置）
    //   1 = get_current_position 直接返回 pos（原始流时间戳）
    //       （ff_ffplay.c:5099-5101）
    { "no-time-adjust",                     "return player's real time from the media stream instead of the adjusted time",
        OPTION_OFFSET(no_time_adjust),      OPTION_INT(0, 0, 1) },

    // 5.1 声道中置声道混音电平。默认 M_SQRT1_2（约 0.707），范围 -32~32。
    // 仅在 5.1 声道下混到立体声时生效。
    { "preset-5-1-center-mix-level",        "preset center-mix-level for 5.1 channel",
        OPTION_OFFSET(preset_5_1_center_mix_level), OPTION_DOUBLE(M_SQRT1_2, -32, 32) },

    /*
     * =====================================================================
     * 十二、Seek 相关
     * =====================================================================
     */

    // 启用精准 seek。默认 0。
    //   0 = 关键帧 seek：跳到最近的关键帧，速度快但位置不精确
    //   1 = 精准 seek：跳到关键帧后再逐帧解码到目标位置，精确但慢
    // RTSP 实时流不需要 seek，建议保持 0。
    { "enable-accurate-seek",                      "enable accurate seek",
        OPTION_OFFSET(enable_accurate_seek),       OPTION_INT(0, 0, 1) },

    // 精准 seek 超时时间（毫秒）。默认 MAX_ACCURATE_SEEK_TIMEOUT。
    // 超过此时间仍未 seek 到目标位置则放弃精准 seek。
    { "accurate-seek-timeout",                      "accurate seek timeout",
        OPTION_OFFSET(accurate_seek_timeout),       OPTION_INT(MAX_ACCURATE_SEEK_TIMEOUT, 0, MAX_ACCURATE_SEEK_TIMEOUT) },

    /*
     * =====================================================================
     * 十三、性能优化
     * =====================================================================
     */

    // 跳过帧率计算。默认 0。
    // 设为 1 时，将 "skip-calc-frame-rate" 写入 ic->metadata 和 format_opts
    // （ff_ffplay.c:3608-3611），传递给 FFmpeg 内部，跳过实际帧率验证。
    // RTSP 摄像头帧率已通过 SDP 声明，建议设为 1 加快 open 速度。
    { "skip-calc-frame-rate",                      "don't calculate real frame rate",
        OPTION_OFFSET(skip_calc_frame_rate),       OPTION_INT(0, 0, 1) },

    // 异步初始化解码器。默认 0。Android MediaCodec 专用选项。
    //   0 = stream_component_open 中同步调用 decoder_init() + pipeline_open 完成初始化
    //   1 = stream_component_open 等待 is->initialized_decoder 变为 1（ff_ffplay.c:3404-3407）
    //       在 stream_open 末尾（ff_ffplay.c:4446-4452）通过 MediaCodec 路径预初始化解码器，
    //       然后设置 initialized_decoder=1 解除 stream_component_open 的阻塞
    // 注意：仅在同时设置了 video-mime-type 和 mediacodec-default-name 时生效。
    // iOS/Apple 平台此参数无效（MediaCodec 路径不执行）。
    { "async-init-decoder",                  "async create decoder",
        OPTION_OFFSET(async_init_decoder),   OPTION_INT(0, 0, 1) },

    // 默认视频 MIME 类型。用于 Android MediaCodec 选择解码器。
    // iOS/Apple 平台此参数无效。
    { "video-mime-type",                    "default video mime type",
        OPTION_OFFSET(video_mime_type),     OPTION_STR(NULL) },

    /*
     * =====================================================================
     * 十四、Apple 平台专属选项
     * =====================================================================
     */

    // VideoToolbox 硬件解码加速。默认 1（启用）。
    // iOS/macOS 上使用硬件芯片解码 H.264/H.265，比软解快数倍，延迟更低，功耗更小。
    // RTSP 监控场景强烈建议保持 1。
    { "videotoolbox_hwaccel",                "default enable ffmpeg hwaccel",
        OPTION_OFFSET(videotoolbox_hwaccel),   OPTION_INT(1, 0, 1) },

    // 启用 CVPixelBuffer 池。默认 1。
    // 设为 1 启用内存池复用 CVPixelBuffer，避免频繁分配/释放。
    // 注意：此 key 是 "enable-cvpixelbufferpool"，不是 "cvpixelbufferpool"。
    // AVOption 的 name 字段带 "enable-" 前缀，结构体成员名才是 cvpixelbufferpool。
    { "enable-cvpixelbufferpool",           "1:enable cvpixelbufferpool improve performance for ffmpeg software decoder avframe -> CVPixelBufferRef;",
        OPTION_OFFSET(cvpixelbufferpool),OPTION_INT(1, 0, 1) },

    // 是否将 VideoToolbox 硬件帧映射到系统内存。默认 0（不拷贝）。
    //   0 = 硬件帧数据保留在 GPU 侧，直接渲染（零拷贝，性能最优）
    //   1 = 对 AV_PIX_FMT_VIDEOTOOLBOX 格式的帧，调用 av_hwframe_map()
    //       将硬件帧映射到系统内存（ff_ffplay.c:253-264）
    // 纯播放场景保持 0，需要截图/滤镜等 CPU 处理时设为 1。
    { "copy_hw_frame",                "default not copy hw data from GPU->CPU",
        OPTION_OFFSET(copy_hw_frame),   OPTION_INT(0, 0, 1) },

    /*
     * =====================================================================
     * 十五、从 ijkplayer 继承的遗留选项
     * =====================================================================
     * 以下选项继承自 Bilibili ijkplayer 项目，原为 Android 平台设计。
     * FSPlayer 是纯 Apple 平台（macOS/iOS）的 fork，这些选项大部分不生效：
     *
     *   mediacodec-*  → 代码中无 #ifdef 守卫，但 mediacodec_default_name 默认为
     *                    NULL，导致 ff_ffplay.c:4446-4452 的条件永远不成立，实际无操作
     *   opensles      → 只在 def.h 中声明和初始化，整个代码库中无任何使用点，死代码
     *   soundtouch    → 有 #if defined(__ANDROID__) 守卫（ff_ffplay.c:2648），
     *                    Apple 平台编译时直接排除
     */

    // MediaCodec H.264 解码（已废弃，请用 mediacodec-avc）
    // FSPlayer 上：mediacodec_default_name 默认为 NULL，条件不成立，无实际效果
    { "mediacodec",                             "MediaCodec: enable H264 (deprecated by 'mediacodec-avc')",
        OPTION_OFFSET(mediacodec_avc),          OPTION_INT(0, 0, 1) },

    // MediaCodec 自动旋转帧（根据视频元数据中的旋转信息）
    // FSPlayer 上：此字段仅在 ff_ffplay_def.h 中存储，无实际使用代码
    { "mediacodec-auto-rotate",                 "MediaCodec: auto rotate frame depending on meta",
        OPTION_OFFSET(mediacodec_auto_rotate),  OPTION_INT(0, 0, 1) },

    // MediaCodec 所有视频格式都启用硬解
    // FSPlayer 上：参与 ff_ffplay.c:4448 条件判断，但外层条件不成立
    { "mediacodec-all-videos",                  "MediaCodec: enable all videos",
        OPTION_OFFSET(mediacodec_all_videos),   OPTION_INT(0, 0, 1) },

    // MediaCodec H.264 硬解
    // FSPlayer 上：参与 ff_ffplay.c:4448 条件判断，但外层条件不成立
    { "mediacodec-avc",                         "MediaCodec: enable H264",
        OPTION_OFFSET(mediacodec_avc),          OPTION_INT(0, 0, 1) },

    // MediaCodec HEVC/H.265 硬解
    // FSPlayer 上：参与 ff_ffplay.c:4448 条件判断，但外层条件不成立
    { "mediacodec-hevc",                        "MediaCodec: enable HEVC",
        OPTION_OFFSET(mediacodec_hevc),         OPTION_INT(0, 0, 1) },

    // MediaCodec MPEG-2 硬解
    // FSPlayer 上：参与 ff_ffplay.c:4448 条件判断，但外层条件不成立
    { "mediacodec-mpeg2",                       "MediaCodec: enable MPEG2VIDEO",
        OPTION_OFFSET(mediacodec_mpeg2),        OPTION_INT(0, 0, 1) },

    // MediaCodec MPEG-4 硬解
    // FSPlayer 上：此字段在 ff_ffplay.c 中无引用，仅在 def.h 中初始化
    { "mediacodec-mpeg4",                       "MediaCodec: enable MPEG4",
        OPTION_OFFSET(mediacodec_mpeg4),        OPTION_INT(0, 0, 1) },

    // MediaCodec 自动处理分辨率变化
    // FSPlayer 上：此字段仅在 ff_ffplay_def.h 中存储，无实际使用代码
    { "mediacodec-handle-resolution-change",                    "MediaCodec: handle resolution change automatically",
        OPTION_OFFSET(mediacodec_handle_resolution_change),     OPTION_INT(0, 0, 1) },

    // OpenSL ES 音频输出（原 Android 低延迟音频 API）
    // FSPlayer 上：整个代码库中无任何使用点，死代码，仅存储值无效果
    { "opensles",                           "OpenSL ES: enable",
        OPTION_OFFSET(opensles),            OPTION_INT(0, 0, 1) },

    // SoundTouch 音效处理（变速/变调）
    // FSPlayer 上：ff_ffplay.c:2648 有 #if defined(__ANDROID__) 守卫，
    // Apple 平台编译时直接排除，无效果
    { "soundtouch",                           "SoundTouch: enable",
        OPTION_OFFSET(soundtouch_enable),            OPTION_INT(0, 0, 1) },

    // MediaCodec 同步模式：使用消息队列同步解码输出
    // FSPlayer 上：此字段仅在 ff_ffplay_def.h 中存储，无实际使用代码
    { "mediacodec-sync",                 "mediacodec: use msg_queue for synchronise",
        OPTION_OFFSET(mediacodec_sync),           OPTION_INT(0, 0, 1) },

    // MediaCodec 默认解码器名称
    // FSPlayer 上：默认为 NULL，导致 ff_ffplay.c:4447 外层条件不成立，
    // 整个 async_init_decoder + MediaCodec 路径被跳过
    { "mediacodec-default-name",          "mediacodec default name",
        OPTION_OFFSET(mediacodec_default_name),      OPTION_STR(NULL) },

    /*
     * =====================================================================
     * 十六、其他选项
     * =====================================================================
     */

    // 延迟初始化元数据。默认 0。
    //   0 = stream_open 末尾调用 ijkmeta_set_avformat_context_l() 立即解析元数据
    //       （ff_ffplay.c:3829-3831）
    //   1 = 推迟到首帧渲染后才调用 ijkmeta_set_avformat_context_l()
    //       （ff_ffplay.c:4292-4296），在 read_thread 主循环中检查
    //       first_video_frame_rendered || first_audio_frame_rendered 条件
    { "ijkmeta-delay-init",          "ijkmeta delay init",
        OPTION_OFFSET(ijkmeta_delay_init),      OPTION_INT(0, 0, 1) },

    // 是否在 prepare 后暂停等待用户调用 play()。默认 0。
    // 与 start-on-prepared 配合工作：
    //
    //   render_wait_start=0, start_on_prepared=1:
    //     stream_open 末尾调用 toggle_pause(1) 暂停，发送 PREPARED，然后阻塞等待
    //     play() 调用后恢复 — 音频/视频渲染立即开始
    //     （ff_ffplay.c:3867-3874）
    //
    //   render_wait_start=1, start_on_prepared=0:
    //     video_image_display2 中等待 pause_req 解除后才渲染（ff_ffplay.c:476-484）
    //     audio callback 中等待 pause_req 解除后才输出（ff_ffplay.c:2934-2938）
    //     也就是说，即使 prepare 完成，音视频渲染也会等到用户调用 play() 后才开始
    //
    // 设为 0：prepare 后自动暂停，play() 后立即渲染（首帧更快）
    // 设为 1：prepare 后不自动暂停，但渲染线程等待 play() 信号
    { "render-wait-start",          "render wait start",
        OPTION_OFFSET(render_wait_start),      OPTION_INT(0, 0, 1) },

    // ICY 元数据更新周期（毫秒）。默认 2000ms。
    // 用于 SHOUTcast/Icecast 流媒体电台的歌曲信息更新。
    { "icy-update-period",                  "set icy meta update period,default is 2000ms",
        OPTION_OFFSET(icy_update_period),       OPTION_INT64(2000, 0, INT_MAX) },
    { NULL }
};

#undef OPTION_STR
#undef OPTION_CONST
#undef OPTION_INT
#undef OPTION_OFFSET

#endif