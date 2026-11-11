/*
 * FSRenderRecorder.m
 *
 * Copyright (c) 2026 debugly <qianlongxu@gmail.com>
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

#import "FSRenderRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import "FSMetalPixelConverter.h"
#include "ijksdl/ijksdl_log.h"
// 待编码帧队列深度：超过即丢帧（丢最旧帧会打乱时间戳，这里直接丢新帧）
static const int kMaxPendingFrames = 60;
// 渲染线程入队的 retained buffer 环上限：这些 buffer 来自解码/渲染池，
// pin 太多会挤占解码器导致播放卡顿，超限直接丢录制帧（保护播放优先）
static const int kMaxRetainedFrames = 4;
// 待编码音频段数上限：播放回调切出的段很小（实测 0.5ms/段），60 段只够 30ms，
// setup（~1s）期间会先于字节上限触发丢音频；字节上限（kMaxPendingAudioBytes）
// 才是真正的内存约束，段数上限只需不先触达
static const int kMaxPendingAudioSegs = 4096;
// 待编码音频队列深度（字节）：约 2 秒 48kHz 立体声 S16
static const int kMaxPendingAudioBytes = 48000 * 2 * 2 * 2;
// 录制帧率上限：渲染源可能高于此值（如 50fps），按 pts 抽帧降到目标帧率，
// 编码量与发热等比下降；源帧率低于此值时不影响（原帧率录制）
static const double kMaxRecordFps = 60.0;
// 音频合段目标时长（秒）：播放回调切出的段极小（实测 0.5ms/段），逐段走
// CMSampleBufferCreate+append 每秒约 2000 次，CPU 白烧且发热；攒够此时长
// 再作为一个段入队，段处理降到 ~50 次/秒
static const double kAudioCoalesceSeconds = 0.02;

// 把 OSType 四字符码转成可读字符串：'420f' 打印为 "420f"，
// 而非 (char*)&t 的小端内存序 "f024"
static const char *dbgFourCC(OSType t, char buf[5])
{
    buf[0] = (char)((t >> 24) & 0xFF);
    buf[1] = (char)((t >> 16) & 0xFF);
    buf[2] = (char)((t >> 8) & 0xFF);
    buf[3] = (char)(t & 0xFF);
    buf[4] = '\0';
    return buf;
}

// 手写 BT.709 full range 色彩转换（Q15/Q16 定点）。不用 vImage 的 420 转换：
// 本机最小验证程序实测 vImageConvert_ARGB8888To420Yp8_CbCr8 返回 noError 时输出
// 仍系统性错乱（输出行映射错乱、UV plane 大片零值 = 解码为绿块），反向函数
// vImageConvert_420Yp8_CbCr8ToARGB8888 在所有尺寸/flags 下都返回 -21766。
// 手写版本经双精度参考验证：正向 yErrAvg≈1、零色度 0；反向 rgbErrAvg=1.1、
// max=3、越界 0/57600；720x1280 正向 ~6ms / 反向 ~12ms，任意 stride 均正确，
// 无需 plane 标准化拷贝。
//
// BGRA（内存序 B,G,R,A）→ NV12（Y 平面 + 交错 CbCr 平面），2x2 色度下采样取平均
static void fsRecConvertBGRAtoNV12(const uint8_t *srcBase, size_t srcStride,
                                   uint8_t *yBase, size_t yStride,
                                   uint8_t *uvBase, size_t uvStride,
                                   int W, int H)
{
    for (int y = 0; y < H; y++) {
        const uint8_t *srow = srcBase + y * srcStride;
        uint8_t *yrow = yBase + y * yStride;
        for (int x = 0; x < W; x++) {
            int b = srow[x*4+0], g = srow[x*4+1], r = srow[x*4+2];
            // Y = 0.2126R + 0.7152G + 0.0722B（Q15）
            int Y = (13933 * r + 46871 * g + 4732 * b) >> 16;
            yrow[x] = (uint8_t)Y;
        }
    }
    for (int y = 0; y < H / 2; y++) {
        const uint8_t *srow0 = srcBase + (y*2) * srcStride;
        const uint8_t *srow1 = srcBase + (y*2+1) * srcStride;
        uint8_t *uvrow = uvBase + y * uvStride;
        for (int x = 0; x < W / 2; x++) {
            // 2x2 平均后做色度
            int b = (srow0[x*8+0] + srow0[x*8+4] + srow1[x*8+0] + srow1[x*8+4]) >> 2;
            int g = (srow0[x*8+1] + srow0[x*8+5] + srow1[x*8+1] + srow1[x*8+5]) >> 2;
            int r = (srow0[x*8+2] + srow0[x*8+6] + srow1[x*8+2] + srow1[x*8+6]) >> 2;
            int Y = (13933 * r + 46871 * g + 4732 * b) >> 16;
            // Cb = 0.5389(B-Y) + 128, Cr = 0.6350(R-Y) + 128（Q15，BT.709）。
            // 饱和色会越界（纯红 Cr≈271、纯蓝 Cb≈262），必须截断，否则 uint8_t
            // 回绕成反色（红块变青块）
            int Cb = ((b - Y) * 35322 >> 16) + 128;
            int Cr = ((r - Y) * 41618 >> 16) + 128;
            uvrow[x*2] = (uint8_t)(Cb < 0 ? 0 : Cb > 255 ? 255 : Cb);
            uvrow[x*2+1] = (uint8_t)(Cr < 0 ? 0 : Cr > 255 ? 255 : Cr);
        }
    }
}

// NV12 → BGRA。Cb/Cr 取该像素所在 2x2 块的值（420 采样语义）
static void fsRecConvertNV12toBGRA(const uint8_t *yBase, size_t yStride,
                                   const uint8_t *uvBase, size_t uvStride,
                                   uint8_t *dstBase, size_t dstStride,
                                   int W, int H)
{
    for (int y = 0; y < H; y++) {
        const uint8_t *yrow = yBase + y * yStride;
        const uint8_t *uvrow = uvBase + (y / 2) * uvStride;
        uint8_t *drow = dstBase + y * dstStride;
        for (int x = 0; x < W; x++) {
            int Y = yrow[x];
            int uIdx = x & ~1;
            int Cb = uvrow[uIdx] - 128;
            int Cr = uvrow[uIdx + 1] - 128;
            // R = Y + 1.5748Cr, G = Y - 0.1873Cb - 0.4681Cr, B = Y + 1.8556Cb（Q16）
            int R = Y + ((103221 * Cr) >> 16);
            int G = Y - ((12272 * Cb + 30678 * Cr) >> 16);
            int B = Y + ((121637 * Cb) >> 16);
            drow[x*4+0] = (uint8_t)(B < 0 ? 0 : B > 255 ? 255 : B);
            drow[x*4+1] = (uint8_t)(G < 0 ? 0 : G > 255 ? 255 : G);
            drow[x*4+2] = (uint8_t)(R < 0 ? 0 : R > 255 ? 255 : R);
            drow[x*4+3] = 255;
        }
    }
}

typedef struct {
    CVPixelBufferRef pixelBuffer; // retained/owned 引用，消费方负责释放
    double pts;                   // 秒
} PendingFrame;

typedef struct {
    uint8_t *data;                // PCM 拷贝，owned
    int bytes;
    double pts;                   // 本段首个样本的时间戳（秒）
} PendingAudio;

@interface FSRenderRecorder ()
{
    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
    AVAssetWriterInput *_audioInput;
    CVPixelBufferPoolRef _bufferPool;   // adaptor 的池，拷贝目标 buffer 从这里取
    OSType _pixelFormat;
    int _width;
    int _height;

    PendingFrame _pending[kMaxPendingFrames];
    int _pendingCount;
    // 渲染线程 → feeder 的 retained 环：渲染线程只 retain+入队（微秒级），
    // memcpy 与 IOSurface 分配全部由 feeder 线程完成——渲染线程做重活会拖慢
    // 直播渲染、延迟持续增大（LatencyBoost 被迫追帧）
    PendingFrame _retained[kMaxRetainedFrames];
    int _retainedCount;
    PendingAudio _pendingAudio[kMaxPendingAudioSegs];
    int _pendingAudioCount;
    int _pendingAudioBytes;
    // 合段缓冲：攒小段 PCM 到 kAudioCoalesceSeconds 再入队（owned，可能为 NULL）
    uint8_t *_audioStaging;
    int _audioStagingCap;   // 已分配容量
    int _audioStagingBytes; // 已攒字节数
    double _audioStagingPts; // 本段首个样本的 pts
    NSLock *_queueLock;

    double _firstPts;     // 首帧 pts，作为时间轴 0
    double _lastPts;      // 上一帧 pts，用于 NAN 时按 fps 递增
    double _lastEnqueuedPts; // 上次实际入队帧的 pts，帧率抽取基准
    double _lastVideoRel; // 上一已喂帧的相对时间，检测 pts 回退/重复（断流重连/seek）
    double _lastAudioRel; // 上一已喂音频段的结束时刻，保证段间不重叠
    BOOL _gotFirstFrame;
    BOOL _gotFirstAudio;
    double _firstAudioPts;
    BOOL _audioAppendFailedLogged;
    BOOL _videoAppendFailedLogged;
    BOOL _droppedAny;
    BOOL _videoRebaseLogged; // 视频 pts 回退（一次性告警）

    // 音频参数（首个音频段确定）
    int _audioSampleRate;
    int _audioChannels;

    dispatch_queue_t _videoWriterQueue;
    dispatch_queue_t _audioWriterQueue;
    // 新帧/新音频信号：feeder 循环无数据时在其上等待。
    // 等待必须发生在自建队列线程上——requestMediaDataWhenReady 的 block 运行在
    // AVF 调度的高 QoS 线程上，在里面阻塞等低 QoS 渲染线程的信号会造成优先级
    // 反转（TPC 告警 + 起播卡顿）；直接 return block 又会被高频重入形成 busy-loop
    dispatch_semaphore_t _videoFeedSem;
    dispatch_semaphore_t _audioFeedSem;
    BOOL _stopping;
    // writer 初始化进行中（startWriting ~1s，已异步化）。期间帧/PCM 照常入
    // pending 队列，setup 完成后由 feeder 统一消化，不丢开头内容
    BOOL _starting;
    // setup 完成前收到 stop：保存 completion，由 setup 块结束时负责收尾回调
    void (^_pendingStopCompletion)(NSError * _Nullable);
    // writer 中途进入 Failed（如断流重连时解码会话重建导致硬编会话失效）时
    // 的错误：自动收尾后存下，stop 时透传给调用方
    NSError *_writerError;

    // ===== 一次性告警标记（每场录制各打一条，不重复） =====
    BOOL _convFailLogged;   // 像素格式转换失败
    BOOL _audioRebaseLogged; // 音频 pts 回退

    // GPU 像素格式转换（BGRA↔NV12）：feeder 线程专用（无锁，单队列约束）
    FSMetalPixelConverter *_gpuConverter;
    id<MTLDevice> _gpuDevice;
    id<MTLCommandQueue> _gpuQueue;
}

@end

@implementation FSRenderRecorder

- (instancetype)init
{
    self = [super init];
    if (self) {
        _queueLock = [[NSLock alloc] init];
        _videoWriterQueue = dispatch_queue_create("com.fsplayer.renderrecorder.video", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_videoWriterQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        _audioWriterQueue = dispatch_queue_create("fsplayer.renderrecorder.audio", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_audioWriterQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        _videoFeedSem = dispatch_semaphore_create(0);
        _audioFeedSem = dispatch_semaphore_create(0);
        _pixelFormat = 0;
        _firstPts = NAN;
        _lastPts = NAN;
        _lastEnqueuedPts = NAN;
    }
    return self;
}

- (void)dealloc
{
    if (_bufferPool) {
        CVPixelBufferPoolRelease(_bufferPool);
    }
    // 正常路径下 stopRecord 已清空队列；兜底释放
    [self _drainPendingBuffers];
    free(_audioStaging);
}

- (BOOL)recording
{
    return (_writer != nil && _writer.status == AVAssetWriterStatusWriting) || _starting;
}

- (void)_setupAudioInputIfNeed
{
    if (_audioInput || _audioSampleRate <= 0 || _audioChannels <= 0) {
        return;
    }
    // 码率按采样率×声道自适应：iOS 硬件 AAC 编码器上限 ≈ sampleRate×3×ch
    // （实测 16kHz mono 48k 过/48.5k 拒，8kHz mono 24k 过/32k 拒，16kHz stereo 96k 过/100k 拒）。
    // 固定 128kbps 在低采样率/单声道（如 16kHz mono）会被拒（-12651），乘 0.9 留余量
    int audioBitRate = (int)MIN(128000, _audioSampleRate * 3.0 * _audioChannels * 0.9);
    NSDictionary *audioSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(_audioSampleRate),
        AVNumberOfChannelsKey: @(_audioChannels),
        AVEncoderBitRateKey: @(audioBitRate),
    };
    _audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                 outputSettings:audioSettings];
    _audioInput.expectsMediaDataInRealTime = YES;
    // 只 addInput；feeder 循环由 startRecord 在 startWriting 成功后统一启动
    // （_startAudioInputFeeding）
    if (_writer && [_writer canAddInput:_audioInput]) {
        [_writer addInput:_audioInput];
    } else {
        _audioInput = nil;
    }
}

- (void)_startAudioInputFeeding
{
    if (!_audioInput) {
        return;
    }
    // 不用 requestMediaDataWhenReady：其 block 运行在 AVF 调度的高 QoS 线程上，
    // 无数据时阻塞等待会造成优先级反转。改为自管理 feeder 循环，主动轮询
    // isReadyForMoreMediaData 并 append，无数据时在自己的低 QoS 线程上等信号
    dispatch_async(_audioWriterQueue, ^{
        [self _audioFeederLoop];
    });
}

/// 音频 feeder 循环：跑在自建的低 QoS 串行队列上，直到 stop 才退出
- (void)_audioFeederLoop
{
    while (!_stopping && _writer && _audioInput) {
        if (![self _feedAudioEncoderInner]) {
            dispatch_semaphore_wait(_audioFeedSem,
                                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)));
        }
    }
}

- (int)startRecord:(NSString *)filePath
       pixelBuffer:(CVPixelBufferRef)pixelBuffer
               fps:(float)fps
       audioSampleRate:(int)audioSampleRate
      audioChannels:(int)audioChannels
          metadata:(nullable NSDictionary<NSString *, NSString *> *)metadata
{
    if (!filePath || !pixelBuffer) {
        return -1;
    }
    if (_writer || _starting) {
        return -2; // already recording / starting
    }

    // 同步部分只做轻量校验与状态复位（微秒级）；writer 创建 + startWriting
    // 实测耗时约 1s（编码管线初始化），必须异步执行，否则调用线程（主线程）
    // 被阻塞，表现为开始录制时画面卡住
    _width = (int)CVPixelBufferGetWidth(pixelBuffer);
    _height = (int)CVPixelBufferGetHeight(pixelBuffer);
    _pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

    // 常见格式都可直接交给 adaptor；不认识的格式退回 BGRA（由调用方保证可转换，
    // 实际上 Metal 渲染路径的 buffer 要么是 NV12/BGRA，要么是 10bit，均受支持）
    switch (_pixelFormat) {
        case kCVPixelFormatType_32BGRA:
        case kCVPixelFormatType_32ARGB:
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8Planar:
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            break;
        default: {
            char fmtStr[5];
            ALOGE("[RenderRecord] unsupported pixel format: %s, abort", dbgFourCC(_pixelFormat, fmtStr));
            return -3;
        }
    }

    [self _resetProgressState];
    _audioSampleRate = (audioSampleRate > 0 && audioChannels > 0) ? audioSampleRate : 0;
    _audioChannels = (audioSampleRate > 0 && audioChannels > 0) ? audioChannels : 0;
    _starting = YES;
    _stopping = NO;
    _convFailLogged = NO;
    _audioRebaseLogged = NO;

    dispatch_async(_videoWriterQueue, ^{
        [self _setupWriterOnQueueWithFilePath:filePath
                                          fps:fps
                              audioSampleRate:audioSampleRate
                                audioChannels:audioChannels
                                     metadata:metadata];
    });
    return 0;
}

/// writer 创建 + startWriting：耗时约 1s，跑在 videoWriterQueue 上。
/// 失败无法同步返回（调用方已拿到 0），只能日志上报并复位状态。
- (void)_setupWriterOnQueueWithFilePath:(NSString *)filePath
                                    fps:(float)fps
                        audioSampleRate:(int)audioSampleRate
                          audioChannels:(int)audioChannels
                               metadata:(nullable NSDictionary<NSString *, NSString *> *)metadata
{
    // setup 期间收到 stop：直接走收尾，不再建 writer
    if (_stopping) {
        _starting = NO;
        [self _finishPendingStop];
        return;
    }
    NSError *error = nil;
    _writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:filePath]
                                        fileType:[self _fileTypeForPath:filePath]
                                           error:&error];
    if (!_writer) {
        ALOGE("[RenderRecord] create writer failed: %s", error.localizedDescription.UTF8String ?: "unknown");
        [self _resetState];
        return;
    }

    if (metadata.count > 0) {
        NSMutableArray<AVMutableMetadataItem *> *items = [NSMutableArray array];
        [metadata enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            AVMutableMetadataItem *item = [[AVMutableMetadataItem alloc] init];
            item.key = key;
            item.keySpace = AVMetadataKeySpaceCommon;
            item.value = value;
            [items addObject:item];
        }];
        _writer.metadata = items;
    }

    // 10bit 用 HEVC，其余 H.264
    BOOL is10bit = (_pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                    _pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);
    AVVideoCodecType codecType = is10bit ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264;

    float fpsValue = (fps > 0.1f && fps < 241.0f) ? fps : 30.0f;
    NSMutableDictionary *compressionProps = [NSMutableDictionary dictionary];
    compressionProps[AVVideoAverageBitRateKey] = @( (int)(MAX(_width, 1) * MAX(_height, 1) * fpsValue * 0.12) );
    compressionProps[AVVideoExpectedSourceFrameRateKey] = @( (int)fpsValue );
    if (!is10bit) {
        compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
    }
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: codecType,
        AVVideoWidthKey: @(_width),
        AVVideoHeightKey: @(_height),
        AVVideoCompressionPropertiesKey: compressionProps,
    };
    _videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    _videoInput.expectsMediaDataInRealTime = YES;

    NSDictionary *adaptorAttributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(_pixelFormat),
        (__bridge NSString *)kCVPixelBufferWidthKey: @(_width),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(_height),
    };
    _adaptor = [AVAssetWriterInputPixelBufferAdaptor
                assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoInput
                                            sourcePixelBufferAttributes:adaptorAttributes];
    if (_adaptor.pixelBufferPool) {
        _bufferPool = CVPixelBufferPoolRetain(_adaptor.pixelBufferPool);
    }

    [_writer addInput:_videoInput];

    // 音频输入必须在 startWriting 之前添加（startWriting 后 canAddInput 返回 NO）。
    // 参数来自播放输出（audio_tgt），无音频流时保持 0，只录视频。
    if (audioSampleRate > 0 && audioChannels > 0) {
        _audioSampleRate = audioSampleRate;
        _audioChannels = audioChannels;
        [self _setupAudioInputIfNeed];
        if (!_audioInput) {
            ALOGE("[RenderRecord] create audio input failed, record video only");
        }
    } else {
        _audioSampleRate = 0;
        _audioChannels = 0;
    }

    // 进度状态已在 startRecord 同步壳中复位；setup 期间攒下的 pending 帧
    // 正是要录的开头内容，此处绝不能再清

    if (![_writer startWriting]) {
        ALOGE("[RenderRecord] startWriting failed: %s", _writer.error.localizedDescription.UTF8String ?: "unknown");
        // 清理残留状态，否则 _writer 非 nil 会挡住后续 startRecord（永久返回 -2）
        [self _resetState];
        return;
    }
    // session 必须在任何 append 之前 start。音视频 pts 都相对首帧归零，
    // 起点固定用 0；不能等视频首帧才 start——音频首段往往先到，append 会被拒
    // （iOS 上返回 NO 并把 writer 置为 Failed，整场录制报废）
    [_writer startSessionAtSourceTime:CMTimeMakeWithSeconds(0, 600)];
    _starting = NO;
    // stop 发生在 setup 中途（错过块开头的检查）：走正常收尾流程
    if (_stopping) {
        [self _teardownAndFinishWriting:_pendingStopCompletion];
        _pendingStopCompletion = nil;
        return;
    }
    dispatch_async(_videoWriterQueue, ^{
        [self _videoFeederLoop];
    });
    [self _startAudioInputFeeding];
}

- (AVFileType)_fileTypeForPath:(NSString *)path
{
    NSString *ext = [path pathExtension].lowercaseString;
    if ([ext isEqualToString:@"mov"]) {
        return AVFileTypeQuickTimeMovie;
    }
    return AVFileTypeMPEG4;
}

- (void)appendPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(double)pts
{
    // _starting 期间也允许入队：setup（~1s）就绪前到达的帧先攒在 retained 环，
    // feeder 启动后统一消化，不丢开头内容
    if (!pixelBuffer || (!(_writer || _starting)) || _stopping) {
        return;
    }

    // 时间戳：优先用帧自带 pts；NAN 时按 fps 递增
    if (isnan(pts) && !isnan(_lastPts)) {
        pts = _lastPts + 1.0 / 30.0;
    }

    // 帧率抽取：仅丢弃"超前但间隔不足"的帧。pts 回退（断流重连/seek 后解码器
    // 重新计数）的帧必须放行——否则重连后新帧要等 pts 追上旧基准（可达十几秒）
    // 才恢复录制，且 feeder 的 rebase 逻辑永远收不到这些帧
    if (!isnan(pts) && !isnan(_lastEnqueuedPts) &&
        pts >= _lastEnqueuedPts &&
        pts - _lastEnqueuedPts < 1.0 / kMaxRecordFps - 1e-6) {
        return;
    }

    // 尺寸不符直接丢；格式不符放行——feeder 拷贝时会转换成录制格式
    // （渲染管线在断流重连/特效开关时可能在 NV12↔BGRA 间切换，直接丢会让
    // 视频轨从切换点起再无新帧，音频继续走，播放表现为画面定格在最后一帧）
    if (CVPixelBufferGetWidth(pixelBuffer) != (size_t)_width ||
        CVPixelBufferGetHeight(pixelBuffer) != (size_t)_height) {
        if (!_droppedAny) {
            _droppedAny = YES;
            ALOGW("[RenderRecord] pixel size mismatch, dropping record frames");
        }
        return;
    }

    // 渲染线程只 retain+入队（微秒级）；memcpy 与 IOSurface 分配全部由
    // feeder 线程完成。环满即丢录制帧——保护播放优先，绝不拖慢渲染
    CVPixelBufferRetain(pixelBuffer);
    [_queueLock lock];
    if (_retainedCount >= kMaxRetainedFrames) {
        [_queueLock unlock];
        CVPixelBufferRelease(pixelBuffer);
        if (!_droppedAny) {
            _droppedAny = YES;
            ALOGW("[RenderRecord] render thread behind, dropping record frames");
        }
        return;
    }
    PendingFrame *slot = &_retained[_retainedCount++];
    slot->pixelBuffer = pixelBuffer;
    slot->pts = pts;
    if (!isnan(pts)) {
        _lastPts = pts;
        _lastEnqueuedPts = pts;
    }
    [_queueLock unlock];
    dispatch_semaphore_signal(_videoFeedSem);
}

- (void)appendAudioSamples:(const int16_t *)samples
                 nbSamples:(int)nbSamples
                sampleRate:(int)sampleRate
                  channels:(int)channels
                       pts:(double)pts
{
    // _starting 期间也允许入队（与 appendPixelBuffer 同理，不丢开头音频）
    if ((!(_writer || _starting)) || _stopping) {
        return;
    }

    // flush 信号：丢弃未编码音频（seek 时音画重新对齐）
    if (!samples || nbSamples < 0) {
        [_queueLock lock];
        for (int i = 0; i < _pendingAudioCount; i++) {
            free(_pendingAudio[i].data);
            _pendingAudio[i].data = NULL;
        }
        _pendingAudioCount = 0;
        _pendingAudioBytes = 0;
        _audioStagingBytes = 0;
        [_queueLock unlock];
        return;
    }

    if (sampleRate <= 0 || channels <= 0) {
        return;
    }

    int bytes = nbSamples * channels * (int)sizeof(int16_t);
    if (bytes <= 0) {
        return;
    }

    // 音频输入在 setup 完成后才存在；_starting 期间按 startRecord 传入的参数校验
    if (!_audioInput && !_starting) {
        return;
    }
    if (sampleRate != _audioSampleRate || channels != _audioChannels) {
        static BOOL warned = NO;
        if (!warned) {
            warned = YES;
            ALOGW("[RenderRecord] audio params mismatch: got %dHz/%dch, expect %dHz/%dch, drop",
                  sampleRate, channels, _audioSampleRate, _audioChannels);
        }
        return;
    }

    // 合段：小段先攒进 staging，攒够 kAudioCoalesceSeconds 再作为一个段入队，
    // 把每秒 ~2000 次的 CMSampleBufferCreate+append 降到 ~50 次（发热优化）。
    // 大段（单段已超过目标时长）或 staging 已有内容时先冲刷，保证顺序与 pts 连续
    int targetBytes = (int)(sampleRate * channels * sizeof(int16_t) * kAudioCoalesceSeconds);
    [_queueLock lock];
    if (_audioStagingBytes > 0 && (_audioStagingBytes + bytes > _audioStagingCap || bytes >= targetBytes)) {
        // staging 非空且本段装不下或本段本身就是大段：先冲刷 staging
        [self _enqueueStagingAudioLocked];
    }
    if (bytes >= targetBytes) {
        // 大段直接入队，不经过 staging
        [self _enqueueAudioSegmentLocked:(const uint8_t *)samples bytes:bytes pts:pts];
        [_queueLock unlock];
        dispatch_semaphore_signal(_audioFeedSem);
        return;
    }
    // 小段：并入 staging
    if (_audioStagingBytes == 0) {
        _audioStagingPts = pts;
    }
    if (_audioStagingBytes + bytes > _audioStagingCap) {
        int newCap = MAX(_audioStagingBytes + bytes, targetBytes * 2);
        uint8_t *grown = realloc(_audioStaging, newCap);
        if (!grown) {
            [_queueLock unlock];
            return;
        }
        _audioStaging = grown;
        _audioStagingCap = newCap;
    }
    memcpy(_audioStaging + _audioStagingBytes, samples, bytes);
    _audioStagingBytes += bytes;
    BOOL flushNow = (_audioStagingBytes >= targetBytes);
    if (flushNow) {
        [self _enqueueStagingAudioLocked];
    }
    [_queueLock unlock];
    if (flushNow) {
        dispatch_semaphore_signal(_audioFeedSem);
    }
}

/// 把 staging 里攒的 PCM 作为一个段入队（持锁调用；staging 状态同步清零）
- (void)_enqueueStagingAudioLocked
{
    if (_audioStagingBytes <= 0) {
        return;
    }
    [self _enqueueAudioSegmentLocked:_audioStaging bytes:_audioStagingBytes pts:_audioStagingPts];
    _audioStagingBytes = 0;
}

/// 入队一段 PCM（持锁调用）。空间不足或 malloc 失败时丢这段（编码器跟不上），
/// 内部持有自己的拷贝
- (void)_enqueueAudioSegmentLocked:(const uint8_t *)samples bytes:(int)bytes pts:(double)pts
{
    if (_pendingAudioCount >= kMaxPendingAudioSegs || _pendingAudioBytes + bytes > kMaxPendingAudioBytes) {
        if (!_droppedAny) {
            _droppedAny = YES;
            ALOGW("[RenderRecord] audio encoder too slow, dropping samples");
        }
        return;
    }

    uint8_t *copy = malloc(bytes);
    if (!copy) {
        return;
    }
    memcpy(copy, samples, bytes);

    PendingAudio *slot = &_pendingAudio[_pendingAudioCount++];
    slot->data = copy;
    slot->bytes = bytes;
    slot->pts = pts;
    _pendingAudioBytes += bytes;
}

/// 纯音频消费循环：把编码器就绪额度内的积压 PCM 全部喂入；返回是否消费过数据
- (BOOL)_feedAudioEncoderInner
{
    if (!_audioInput) {
        return NO;
    }
    BOOL appendedAny = NO;
    while (_audioInput.isReadyForMoreMediaData) {
        [_queueLock lock];
        if (_pendingAudioCount == 0) {
            [_queueLock unlock];
            return appendedAny;
        }
        PendingAudio seg = _pendingAudio[0];
        memmove(&_pendingAudio[0], &_pendingAudio[1], sizeof(PendingAudio) * (_pendingAudioCount - 1));
        _pendingAudioCount--;
        _pendingAudioBytes -= seg.bytes;
        [_queueLock unlock];
        appendedAny = YES;

        // 首个音频段：记录时间轴基准；pts 为 NAN 时不能当基准（会污染后续
        // 所有段的 segStart），跳过等下一段
        if (isnan(seg.pts)) {
            free(seg.data);
            continue;
        }
        if (!_gotFirstAudio) {
            _gotFirstAudio = YES;
            _firstAudioPts = seg.pts;
        }

        // 按样本数推进的段内 pts；回退或重叠（断流重连/seek）时从上一段
        // 结束处继续——与视频侧同理，输出时间轴必须严格不回退不重叠
        int bytesPerSample = 2 * _audioChannels;
        double segDur = (double)seg.bytes / bytesPerSample / MAX(_audioSampleRate, 1);
        double segStart = seg.pts - _firstAudioPts;
        if (segStart < _lastAudioRel) {
            if (!_audioRebaseLogged) {
                _audioRebaseLogged = YES;
                ALOGW("[RenderRecord] audio pts went backwards/dup, rebase to %.3f (src pts %.3f)",
                      _lastAudioRel, seg.pts);
            }
            segStart = _lastAudioRel;
        }
        if (segStart < 0) {
            segStart = 0;
        }
        _lastAudioRel = segStart + segDur;

        CMTime pts = CMTimeMakeWithSeconds(segStart, 600);
        CMTime duration = CMTimeMakeWithSeconds(segDur, 600);

        CMAudioFormatDescriptionRef format = NULL;
        AudioStreamBasicDescription asbd = {0};
        asbd.mSampleRate = (Float64)MAX(_audioSampleRate, 1);
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        asbd.mBytesPerPacket = bytesPerSample;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerFrame = bytesPerSample;
        asbd.mChannelsPerFrame = _audioChannels;
        asbd.mBitsPerChannel = 16;
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &format);
        if (!format) {
            free(seg.data);
            continue;
        }

        CMBlockBufferRef blockBuffer = NULL;
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault, seg.data, seg.bytes, kCFAllocatorNull,
            NULL, 0, seg.bytes, 0, &blockBuffer);
        if (status == kCMBlockBufferNoErr && blockBuffer) {
            CMSampleTimingInfo timing = { duration, pts, kCMTimeInvalid };
            CMSampleBufferRef sampleBuffer = NULL;
            // sampleSizeArray 语义是"每个样本的字节数"，必须传 bytesPerSample；
            // 传整段 bytes 会被算成 numSamples*bytes 的总大小，编码器直接拒绝
            size_t sampleSizeEntry = (size_t)bytesPerSample;
            status = CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, TRUE,
                                          NULL, NULL, format, seg.bytes / bytesPerSample,
                                          1, &timing, 1, &sampleSizeEntry, &sampleBuffer);
            if (status == noErr && sampleBuffer) {
                if (![_audioInput appendSampleBuffer:sampleBuffer]) {
                    // 首次失败时把底层 OSStatus 和完整参数打出来，便于定位编码器拒绝原因
                    if (!_audioAppendFailedLogged) {
                        _audioAppendFailedLogged = YES;
                        NSError *err = _writer.error;
                        NSError *under = err.userInfo[NSUnderlyingErrorKey];
                        ALOGE("[RenderRecord] appendSampleBuffer failed: code=%ld, under=%ld, "
                              "%dHz/%dch, segBytes=%d, numSamples=%d, bps=%d, dur=%.4f, pts=%.4f, status=%ld",
                              (long)err.code, (long)(under ? under.code : 0),
                              _audioSampleRate, _audioChannels, seg.bytes, seg.bytes / bytesPerSample,
                              bytesPerSample, CMTimeGetSeconds(duration), CMTimeGetSeconds(pts),
                              (long)_writer.status);
                    }
                    if (_writer.status == AVAssetWriterStatusFailed) {
                        // writer 已进入 Failed，自动收尾并停止编码循环
                        free(seg.data);
                        CFRelease(sampleBuffer);
                        CFRelease(blockBuffer);
                        CFRelease(format);
                        [self _abortOnWriterFailure];
                        return appendedAny;
                    }
                }
                CFRelease(sampleBuffer);
            } else {
                ALOGE("[RenderRecord] CMSampleBufferCreate failed: %d", (int)status);
            }
            CFRelease(blockBuffer);
        }
        CFRelease(format);
        free(seg.data);
    }
    return appendedAny;
}

/// 从 retained 源 buffer 拷贝生成自有副本（feeder 线程调用）。
/// 优先从 adaptor 池取，池不可用时直接创建。返回 retained 的 buffer 或 NULL。
- (CVPixelBufferRef)_copyPixelBuffer:(CVPixelBufferRef)src
{
    CVPixelBufferRef dst = NULL;
    OSType srcFmt = CVPixelBufferGetPixelFormatType(src);
    if (_bufferPool) {
        CVReturn ret = CVPixelBufferPoolCreatePixelBuffer(NULL, _bufferPool, &dst);
        if (ret != kCVReturnSuccess) {
            dst = NULL;
        }
    }
    if (!dst) {
        // pool 不可用时直接创建
        CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault,
                                           (size_t)_width, (size_t)_height,
                                           _pixelFormat, NULL, &dst);
        if (ret != kCVReturnSuccess) {
            return NULL;
        }
    }
    if (CVPixelBufferGetWidth(dst) != (size_t)_width || CVPixelBufferGetHeight(dst) != (size_t)_height) {
        CVPixelBufferRelease(dst);
        return NULL;
    }

    // 源格式与录制格式一致：逐 plane 拷贝（兼容 planar/chunky 两种布局）
    if (srcFmt == _pixelFormat) {
        CVReturn ret = kCVReturnSuccess;
        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(dst, 0);
        size_t planeCount = CVPixelBufferIsPlanar(src) ? CVPixelBufferGetPlaneCount(src) : 1;
        for (size_t i = 0; i < planeCount && ret == kCVReturnSuccess; i++) {
            void *srcBase = planeCount > 1 ? CVPixelBufferGetBaseAddressOfPlane(src, i) : CVPixelBufferGetBaseAddress(src);
            void *dstBase = planeCount > 1 ? CVPixelBufferGetBaseAddressOfPlane(dst, i) : CVPixelBufferGetBaseAddress(dst);
            size_t srcStride = planeCount > 1 ? CVPixelBufferGetBytesPerRowOfPlane(src, i) : CVPixelBufferGetBytesPerRow(src);
            size_t dstStride = planeCount > 1 ? CVPixelBufferGetBytesPerRowOfPlane(dst, i) : CVPixelBufferGetBytesPerRow(dst);
            size_t height = planeCount > 1 ? CVPixelBufferGetHeightOfPlane(src, i) : CVPixelBufferGetHeight(src);
            if (!srcBase || !dstBase) {
                ret = kCVReturnError;
                break;
            }
            if (srcStride == dstStride) {
                memcpy(dstBase, srcBase, srcStride * height);
            } else {
                // stride 不同时逐行拷贝有效宽度（取两者较小值）
                size_t copyBytes = MIN(srcStride, dstStride);
                uint8_t *s = (uint8_t *)srcBase;
                uint8_t *d = (uint8_t *)dstBase;
                for (size_t row = 0; row < height; row++) {
                    memcpy(d + row * dstStride, s + row * srcStride, copyBytes);
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(dst, 0);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        if (ret != kCVReturnSuccess) {
            CVPixelBufferRelease(dst);
            return NULL;
        }
        return dst;
    }

    // 源格式不同（渲染管线在断流重连/特效开关时切换 NV12↔BGRA）：转换成
    // 录制格式，否则视频轨从切换点起再无新帧（画面定格）。仅支持常见的
    // NV12/BGRA/ARGB 互转，其余格式丢弃该帧
    return [self _convertPixelBuffer:src toFormat:_pixelFormat into:dst];
}

/// 把 src（NV12/BGRA/ARGB 之一）转换成 dst 的格式并写入（feeder 线程调用）。
/// 色彩按 BT.709 full range（渲染管线日志实锤的输出参数），用手写定点转换
/// （fsRecConvertBGRAtoNV12 / fsRecConvertNV12toBGRA，见文件头部说明——vImage
/// 的 420 转换函数实测输出错乱/直接报错，不可用）。
/// 返回 dst（成功，调用方持有）或 NULL（不支持的格式组合，调用方应丢帧）
- (CVPixelBufferRef)_convertPixelBuffer:(CVPixelBufferRef)src
                               toFormat:(OSType)dstFmt
                                   into:(CVPixelBufferRef)dst
{
    OSType srcFmt = CVPixelBufferGetPixelFormatType(src);
    OSType dstFmtReal = CVPixelBufferGetPixelFormatType(dst);

    // GPU 快速路径：BGRA↔NV12 走 Metal compute（<1ms，CPU 标量版 6-12ms）。
    // 首次惰性创建（feeder 线程专用，单队列无锁）；创建或转换失败回落 CPU 路径
    if (!_gpuConverter) {
        if (!_gpuDevice) {
            _gpuDevice = MTLCreateSystemDefaultDevice();
            _gpuQueue = [_gpuDevice newCommandQueue];
        }
        if (_gpuDevice && _gpuQueue) {
            _gpuConverter = [[FSMetalPixelConverter alloc] initWithDevice:_gpuDevice
                                                            commandQueue:_gpuQueue];
        }
    }
    if (_gpuConverter && [_gpuConverter convert:src to:dst]) {
        return dst;
    }
    if (_gpuConverter) {
        // GPU 路径对这组 buffer 失败（如非 IOSurface-backed）：本次回落 CPU，
        // 转换器保留，下帧继续尝试 GPU
        static BOOL gpuFailLogged = NO;
        if (!gpuFailLogged) {
            gpuFailLogged = YES;
            ALOGW("[RenderRecord] gpu convert failed once, fallback to CPU path");
        }
    }

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    // 统一走"源 → BGRA 中转 → 目标"路径；BGRA→BGRA 之外的每步都直接写目标
    // 布局（手写转换支持任意 stride，无需 plane 标准化拷贝）
    uint8_t *tmpBGRA = NULL;
    size_t bgraStride = 0;         // 中转 BGRA 的实际 stride
    CVPixelBufferRef result = NULL;
    const char *failStep = NULL;   // 失败步骤名（诊断日志用）
    char srcStr[5], dstStr[5];
    dbgFourCC(srcFmt, srcStr);

    if (srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        const uint8_t *srcY = CVPixelBufferGetBaseAddressOfPlane(src, 0);
        const uint8_t *srcUV = CVPixelBufferGetBaseAddressOfPlane(src, 1);
        size_t srcYStride = CVPixelBufferGetBytesPerRowOfPlane(src, 0);
        size_t srcUVStride = CVPixelBufferGetBytesPerRowOfPlane(src, 1);
        if (!srcY || !srcUV) {
            failStep = "src plane addr";
            goto done;
        }
        tmpBGRA = malloc((size_t)_width * _height * 4);
        if (!tmpBGRA) {
            failStep = "malloc tmpBGRA";
            goto done;
        }
        fsRecConvertNV12toBGRA(srcY, srcYStride, srcUV, srcUVStride,
                               tmpBGRA, (size_t)_width * 4, _width, _height);
        bgraStride = (size_t)_width * 4;
    } else if (srcFmt == kCVPixelFormatType_32BGRA) {
        tmpBGRA = CVPixelBufferGetBaseAddress(src); // 直接引用，不 free
        bgraStride = CVPixelBufferGetBytesPerRow(src);
    } else if (srcFmt == kCVPixelFormatType_32ARGB) {
        // 内存序 A,R,G,B → B,G,R,A：交换前 3 字节
        tmpBGRA = malloc((size_t)_width * _height * 4);
        if (!tmpBGRA) {
            failStep = "malloc tmpBGRA";
            goto done;
        }
        const uint8_t *sbase = CVPixelBufferGetBaseAddress(src);
        size_t sstride = CVPixelBufferGetBytesPerRow(src);
        for (int y = 0; y < _height; y++) {
            const uint8_t *srow = sbase + y * sstride;
            uint8_t *drow = tmpBGRA + y * (size_t)_width * 4;
            for (int x = 0; x < _width; x++) {
                drow[x*4+0] = srow[x*4+3];
                drow[x*4+1] = srow[x*4+2];
                drow[x*4+2] = srow[x*4+1];
                drow[x*4+3] = srow[x*4+0];
            }
        }
        bgraStride = (size_t)_width * 4;
    } else {
        failStep = "unsupported src fmt";
        goto done; // 不支持的源格式
    }

    // BGRA 中转 → 目标格式
    if (dstFmtReal == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        dstFmtReal == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
        uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
        size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
        size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);
        if (!dstY || !dstUV) {
            failStep = "dst plane addr";
            goto done;
        }
        fsRecConvertBGRAtoNV12(tmpBGRA, bgraStride,
                               dstY, dstYStride, dstUV, dstUVStride,
                               _width, _height);
    } else if (dstFmtReal == kCVPixelFormatType_32BGRA) {
        void *dstBase = CVPixelBufferGetBaseAddress(dst);
        size_t dstStride = CVPixelBufferGetBytesPerRow(dst);
        if (!dstBase) {
            failStep = "dst plane addr";
            goto done;
        }
        for (int row = 0; row < _height; row++) {
            memcpy((uint8_t *)dstBase + row * dstStride,
                   tmpBGRA + row * bgraStride, (size_t)_width * 4);
        }
    } else if (dstFmtReal == kCVPixelFormatType_32ARGB) {
        // 内存序 B,G,R,A → A,R,G,B
        uint8_t *dstBase = CVPixelBufferGetBaseAddress(dst);
        size_t dstStride = CVPixelBufferGetBytesPerRow(dst);
        if (!dstBase) {
            failStep = "dst plane addr";
            goto done;
        }
        for (int y = 0; y < _height; y++) {
            const uint8_t *srow = tmpBGRA + y * bgraStride;
            uint8_t *drow = dstBase + y * dstStride;
            for (int x = 0; x < _width; x++) {
                drow[x*4+0] = srow[x*4+3];
                drow[x*4+1] = srow[x*4+2];
                drow[x*4+2] = srow[x*4+1];
                drow[x*4+3] = srow[x*4+0];
            }
        }
    } else {
        failStep = "unsupported dst fmt";
        goto done; // 不支持的目标格式
    }
    result = dst; // 转换成功

done:
    // tmpBGRA 可能直接引用 src 的 base address（BGRA→BGRA 路径），只在堆分配时 free
    if (tmpBGRA && tmpBGRA != CVPixelBufferGetBaseAddress(src)) {
        free(tmpBGRA);
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    if (!result && !_convFailLogged) {
        _convFailLogged = YES;
        char dstStr[5];
        dbgFourCC(CVPixelBufferGetPixelFormatType(dst), dstStr);
        ALOGE("[RenderRecord] convert failed: step=%s, src=%s, dst=%s",
              failStep ?: "?", srcStr, dstStr);
    }
    return result;
}

/// 把 retained 环里的帧拷贝进 pending 队列（feeder 线程调用）。
/// retained 环最多 pin kMaxRetainedFrames 个解码池 buffer，feeder 每轮立即
/// 搬空，解码器几乎不受影响；pending 满时直接丢 retained 帧，保护播放优先
- (void)_drainRetainedFrames
{
    for (;;) {
        [_queueLock lock];
        if (_retainedCount == 0) {
            [_queueLock unlock];
            return;
        }
        if (_pendingCount >= kMaxPendingFrames) {
            // 编码器跟不上：丢弃 retained 帧而不是拷贝后丢，省一次白拷贝
            while (_retainedCount > 0) {
                PendingFrame rf = _retained[--_retainedCount];
                CVPixelBufferRelease(rf.pixelBuffer);
            }
            [_queueLock unlock];
            if (!_droppedAny) {
                _droppedAny = YES;
                ALOGW("[RenderRecord] encoder too slow, dropping record frames");
            }
            return;
        }
        PendingFrame rf = _retained[0];
        memmove(&_retained[0], &_retained[1], sizeof(PendingFrame) * (_retainedCount - 1));
        _retainedCount--;
        [_queueLock unlock];

        CVPixelBufferRef copy = [self _copyPixelBuffer:rf.pixelBuffer];
        CVPixelBufferRelease(rf.pixelBuffer);
        if (!copy) {
            continue;
        }

        [_queueLock lock];
        if (_pendingCount >= kMaxPendingFrames) {
            [_queueLock unlock];
            CVPixelBufferRelease(copy);
            continue;
        }
        _pending[_pendingCount++] = (PendingFrame){ copy, rf.pts };
        [_queueLock unlock];
    }
}

/// 视频 feeder 循环：跑在自建的低 QoS 串行队列上，直到 stop 才退出
- (void)_videoFeederLoop
{
    while (!_stopping && _writer && _videoInput) {
        [self _drainRetainedFrames];
        BOOL fed = [self _feedEncoderInner];
        if (!fed) {
            dispatch_semaphore_wait(_videoFeedSem,
                                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)));
        }
    }
}

/// 纯视频消费循环：把编码器就绪额度内的积压帧全部喂入；返回是否消费过数据
- (BOOL)_feedEncoderInner
{
    BOOL appendedAny = NO;
    while (_videoInput.isReadyForMoreMediaData) {
        [_queueLock lock];
        if (_pendingCount == 0) {
            [_queueLock unlock];
            return appendedAny;
        }
        // 取最旧的一帧
        PendingFrame frame = _pending[0];
        memmove(&_pending[0], &_pending[1], sizeof(PendingFrame) * (_pendingCount - 1));
        _pendingCount--;
        [_queueLock unlock];
        appendedAny = YES;

        if (!_gotFirstFrame) {
            _firstPts = isnan(frame.pts) ? 0 : frame.pts;
            _gotFirstFrame = YES;
            // session 已在 startRecord 中提前 start（起点 0），此处只记录首帧 pts 基准
        }
        // 相对首帧的时间轴；pts 回退或重复（断流重连/seek 后解码器重新计数、
        // 断流边界重复 emit）都会被 AVAssetWriter 拒绝（-11800/-19640）并置
        // Failed——平移基准让输出时间轴从断点严格递增地继续
        double rel = frame.pts - _firstPts;
        if (isnan(rel)) {
            rel = _lastVideoRel + 1.0 / kMaxRecordFps;
        }
        if (rel <= _lastVideoRel) {
            _firstPts = frame.pts - _lastVideoRel;
            rel = _lastVideoRel + 1.0 / kMaxRecordFps;
            if (!_videoRebaseLogged) {
                _videoRebaseLogged = YES;
                ALOGW("[RenderRecord] video pts went backwards/dup, rebase to %.3f (src pts %.3f)",
                      rel, frame.pts);
            }
        }
        if (rel < 0) {
            rel = 0;
        }
        _lastVideoRel = rel;
        CMTime pts = CMTimeMakeWithSeconds(rel, 600);
        if (![_adaptor appendPixelBuffer:frame.pixelBuffer withPresentationTime:pts]) {
            if (!_videoAppendFailedLogged) {
                _videoAppendFailedLogged = YES;
                NSError *err = _writer.error;
                NSError *under = err.userInfo[NSUnderlyingErrorKey];
                char fmtStr[5];
                ALOGE("[RenderRecord] appendPixelBuffer failed: code=%ld, under=%ld, "
                      "%dx%d, fmt=%s, pts=%.4f, status=%ld",
                      (long)err.code, (long)(under ? under.code : 0),
                      _width, _height, dbgFourCC(_pixelFormat, fmtStr), CMTimeGetSeconds(pts),
                      (long)_writer.status);
            }
            if (_writer.status == AVAssetWriterStatusFailed) {
                // writer 已进入 Failed，后续 append 全部无效，自动收尾并停止编码循环
                CVPixelBufferRelease(frame.pixelBuffer);
                [self _abortOnWriterFailure];
                return appendedAny;
            }
        }
        CVPixelBufferRelease(frame.pixelBuffer);
    }
    return appendedAny;
}

- (void)stopRecordWithCompletion:(void (^)(NSError * _Nullable error))completion
{
    // setup（startWriting ~1s）进行中收到 stop：记下 completion，由 setup 块
    // 结束时统一收尾；setup 块开头检查 _stopping 也会直接走收尾。
    // 已有待回调的 completion 时先回调它，避免被覆盖后永不回调
    if (_starting) {
        void (^prev)(NSError * _Nullable) = _pendingStopCompletion;
        _pendingStopCompletion = [completion copy];
        _stopping = YES;
        [self _drainPendingBuffers];
        if (prev) {
            prev(nil);
        }
        return;
    }
    if (!_writer) {
        if (completion) {
            completion(nil);
        }
        return;
    }
    [self _teardownAndFinishWriting:completion];
}

/// 停止录制收尾：drain 积压 → 置空 writer 引用 → markAsFinished → finishWriting。
/// completion（可空）在文件完全写完后回调一次。
- (void)_teardownAndFinishWriting:(void (^)(NSError * _Nullable error))completion
{
    _stopping = YES;

    // 取出所有未编码的 buffer，避免泄漏（来不及编码的直接丢弃）
    [self _drainPendingBuffers];

    // 局部持有，writer 置 nil 后 block 仍能收尾
    AVAssetWriterInput *input = _videoInput;
    AVAssetWriterInput *audioInput = _audioInput;
    AVAssetWriter *writer = _writer;
    dispatch_queue_t videoQueue = _videoWriterQueue;
    dispatch_semaphore_t videoSem = _videoFeedSem;
    dispatch_semaphore_t audioSem = _audioFeedSem;

    _writer = nil;
    _videoInput = nil;
    _adaptor = nil;
    _audioInput = nil;
    if (_bufferPool) {
        CVPixelBufferPoolRelease(_bufferPool);
        _bufferPool = NULL;
    }
    _gpuConverter = nil;

    // 唤醒可能正阻塞在信号量上的 feeder 循环（_stopping 已置 YES，醒来后会退出）
    dispatch_semaphore_signal(videoSem);
    dispatch_semaphore_signal(audioSem);

    dispatch_async(videoQueue, ^{
        // 队列已被 drain，此后不会再有 append；finishWriting 自身会等所有已
        // append 的数据编码完成、moov 落盘后才回调，无需在此轮询等待
        [input markAsFinished];
        [audioInput markAsFinished];
        [writer finishWritingWithCompletionHandler:^{
            ALOGI("[RenderRecord] finished, status=%ld, error=%s", (long)writer.status,
                  writer.error.localizedDescription.UTF8String ?: "none");
            if (completion) {
                completion(writer.error ?: self->_writerError);
            }
        }];
    });
}

/// writer 中途进入 Failed 时从 feeder 线程调用：存下错误并自动收尾，
/// 让 recording 立即变 NO、后续 append 静默丢弃，stop 时能拿到真实错误
- (void)_abortOnWriterFailure
{
    if (_stopping || !_writer) {
        return;
    }
    _writerError = _writer.error;
    ALOGE("[RenderRecord] writer failed mid-record, auto-finishing: %s",
          _writer.error.localizedDescription.UTF8String ?: "unknown");
    [self _teardownAndFinishWriting:nil];
}

/// setup 期间收到 stop 的收尾：回调保存的 completion（无 writer，无数据可写）
- (void)_finishPendingStop
{
    void (^completion)(NSError * _Nullable) = _pendingStopCompletion;
    _pendingStopCompletion = nil;
    if (completion) {
        completion(nil);
    }
}

/// 复位录制进度状态（不动 writer/输入资源）。
/// 注意：会先 drain pending 队列（释放未消费的 buffer/PCM）
- (void)_resetProgressState
{
    [self _drainPendingBuffers];
    _firstPts = NAN;
    _lastPts = NAN;
    _lastEnqueuedPts = NAN;
    _lastVideoRel = -1.0; // -1 而非 0：首帧 rel=0 不应被误判为 pts 回退
    _lastAudioRel = 0;
    _gotFirstFrame = NO;
    _gotFirstAudio = NO;
    _firstAudioPts = 0;
    _audioAppendFailedLogged = NO;
    _videoAppendFailedLogged = NO;
    _droppedAny = NO;
    _videoRebaseLogged = NO;
    _audioStagingBytes = 0;
}

/// startRecord 失败路径的统一清理：释放 writer 相关资源并复位状态，
/// 保证调用方之后可以重新 startRecord（否则残留的 _writer 会让重试永远返回 -2）
- (void)_resetState
{
    if (_writer) {
        [_writer cancelWriting];
    }
    _writer = nil;
    _videoInput = nil;
    _adaptor = nil;
    _audioInput = nil;
    _audioSampleRate = 0;
    _audioChannels = 0;
    if (_bufferPool) {
        CVPixelBufferPoolRelease(_bufferPool);
        _bufferPool = NULL;
    }
    _gpuConverter = nil;
    _gpuDevice = nil;
    _gpuQueue = nil;
    _starting = NO;
    _stopping = NO;
    _writerError = nil;
    [self _resetProgressState];
}

- (void)_drainPendingBuffers
{
    [_queueLock lock];
    for (int i = 0; i < _retainedCount; i++) {
        CVPixelBufferRelease(_retained[i].pixelBuffer);
        _retained[i].pixelBuffer = NULL;
    }
    _retainedCount = 0;
    for (int i = 0; i < _pendingCount; i++) {
        if (_pending[i].pixelBuffer) {
            CVPixelBufferRelease(_pending[i].pixelBuffer);
            _pending[i].pixelBuffer = NULL;
        }
    }
    _pendingCount = 0;
    for (int i = 0; i < _pendingAudioCount; i++) {
        free(_pendingAudio[i].data);
        _pendingAudio[i].data = NULL;
    }
    _pendingAudioCount = 0;
    _pendingAudioBytes = 0;
    [_queueLock unlock];
}

@end
