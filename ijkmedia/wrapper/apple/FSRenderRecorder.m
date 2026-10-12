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
#import <mach/mach_time.h>
// 待编码帧队列深度：超过即丢帧（丢最旧帧会打乱时间戳，这里直接丢新帧）
static const int kMaxPendingFrames = 60;
// 待编码音频队列深度（字节）：约 2 秒 48kHz 立体声 S16
static const int kMaxPendingAudioBytes = 48000 * 2 * 2 * 2;

typedef struct {
    CVPixelBufferRef pixelBuffer; // 拷贝出来的副本，owned
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
    PendingAudio _pendingAudio[kMaxPendingFrames];
    int _pendingAudioCount;
    int _pendingAudioBytes;
    NSLock *_queueLock;

    double _firstPts;     // 首帧 pts，作为时间轴 0
    double _lastPts;      // 上一帧 pts，用于 NAN 时按 fps 递增
    BOOL _gotFirstFrame;
    BOOL _gotFirstAudio;
    double _firstAudioPts;
    BOOL _droppedAny;

    // 音频参数（首个音频段确定）
    int _audioSampleRate;
    int _audioChannels;

    dispatch_queue_t _writerQueue;
    BOOL _stopping;
}

@end

@implementation FSRenderRecorder

- (instancetype)init
{
    self = [super init];
    if (self) {
        _queueLock = [[NSLock alloc] init];
        _writerQueue = dispatch_queue_create("com.fsplayer.renderrecorder", DISPATCH_QUEUE_SERIAL);
        _pixelFormat = 0;
        _firstPts = NAN;
        _lastPts = NAN;
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
}

- (BOOL)recording
{
    return _writer != nil && _writer.status == AVAssetWriterStatusWriting;
}

- (void)_setupAudioInputIfNeed
{
    if (_audioInput || _audioSampleRate <= 0 || _audioChannels <= 0) {
        return;
    }
    NSDictionary *audioSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(_audioSampleRate),
        AVNumberOfChannelsKey: @(_audioChannels),
        AVEncoderBitRateKey: @(128000),
    };
    _audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                 outputSettings:audioSettings];
    _audioInput.expectsMediaDataInRealTime = YES;
    if (_writer && [_writer canAddInput:_audioInput]) {
        [_writer addInput:_audioInput];
        __weak typeof(self) wself = self;
        [_audioInput requestMediaDataWhenReadyOnQueue:_writerQueue usingBlock:^{
            [wself _feedAudioEncoder];
        }];
    } else {
        _audioInput = nil;
    }
}

- (int)startRecord:(NSString *)filePath
       pixelBuffer:(CVPixelBufferRef)pixelBuffer
               fps:(float)fps
          metadata:(nullable NSDictionary<NSString *, NSString *> *)metadata
{
    if (!filePath || !pixelBuffer) {
        return -1;
    }
    if (_writer) {
        return -2; // already recording
    }

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
        default:
            NSLog(@"[RenderRecord] unsupported pixel format: %@, abort", @( (char *)&_pixelFormat ));
            return -3;
    }

    NSError *error = nil;
    _writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:filePath]
                                        fileType:[self _fileTypeForPath:filePath]
                                           error:&error];
    if (!_writer) {
        NSLog(@"[RenderRecord] create writer failed: %@", error);
        return -4;
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

    _firstPts = NAN;
    _lastPts = NAN;
    _gotFirstFrame = NO;
    _gotFirstAudio = NO;
    _firstAudioPts = 0;
    _droppedAny = NO;
    _stopping = NO;
    _pendingCount = 0;
    _pendingAudioCount = 0;
    _pendingAudioBytes = 0;
    _audioSampleRate = 0;
    _audioChannels = 0;

    if (![_writer startWriting]) {
        NSLog(@"[RenderRecord] startWriting failed: %@", _writer.error);
        return -5;
    }
    __weak typeof(self) wself = self;
    [_videoInput requestMediaDataWhenReadyOnQueue:_writerQueue usingBlock:^{
        [wself _feedEncoder];
    }];

    NSLog(@"[RenderRecord] started: %@, %dx%d, fmt=%4s, fps=%.1f",
          filePath, _width, _height, (char *)&_pixelFormat, fpsValue);
    return 0;
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
    if (!pixelBuffer || !_writer || _stopping) {
        return;
    }

    // 时间戳：优先用帧自带 pts；NAN 时按 fps 递增
    if (isnan(pts) && !isnan(_lastPts)) {
        pts = _lastPts + 1.0 / 30.0;
    }

    [_queueLock lock];
    if (_pendingCount >= kMaxPendingFrames) {
        [_queueLock unlock];
        if (!_droppedAny) {
            _droppedAny = YES;
            NSLog(@"[RenderRecord] encoder too slow, dropping frames");
        }
        return;
    }

    // 立即拷贝像素：传入的 buffer 属于解码器输出池，返回后会被回收复用
    CVPixelBufferRef copy = [self _copyPixelBuffer:pixelBuffer];
    if (!copy) {
        [_queueLock unlock];
        return;
    }

    PendingFrame *slot = &_pending[_pendingCount++];
    slot->pixelBuffer = copy;
    slot->pts = pts;
    if (!isnan(pts)) {
        _lastPts = pts;
    }
    [_queueLock unlock];
}

- (void)appendAudioSamples:(const int16_t *)samples
                 nbSamples:(int)nbSamples
                sampleRate:(int)sampleRate
                  channels:(int)channels
                       pts:(double)pts
{
    if (!_writer || _stopping) {
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

    // 首段确定音频参数并惰性创建音频输入
    if (_audioSampleRate == 0) {
        _audioSampleRate = sampleRate;
        _audioChannels = channels;
        [self _setupAudioInputIfNeed];
        if (!_audioInput) {
            NSLog(@"[RenderRecord] create audio input failed, record video only");
        }
    }
    if (!_audioInput) {
        return;
    }

    [_queueLock lock];
    if (_pendingAudioCount >= kMaxPendingFrames || _pendingAudioBytes + bytes > kMaxPendingAudioBytes) {
        [_queueLock unlock];
        if (!_droppedAny) {
            _droppedAny = YES;
            NSLog(@"[RenderRecord] audio encoder too slow, dropping samples");
        }
        return;
    }

    uint8_t *copy = malloc(bytes);
    if (!copy) {
        [_queueLock unlock];
        return;
    }
    memcpy(copy, samples, bytes);

    PendingAudio *slot = &_pendingAudio[_pendingAudioCount++];
    slot->data = copy;
    slot->bytes = bytes;
    slot->pts = pts;
    _pendingAudioBytes += bytes;
    [_queueLock unlock];
}

- (void)_feedAudioEncoder
{
    if (!_audioInput) {
        return;
    }

    while (_audioInput.isReadyForMoreMediaData) {
        [_queueLock lock];
        if (_pendingAudioCount == 0) {
            [_queueLock unlock];
            break;
        }
        PendingAudio seg = _pendingAudio[0];
        memmove(&_pendingAudio[0], &_pendingAudio[1], sizeof(PendingAudio) * (_pendingAudioCount - 1));
        _pendingAudioCount--;
        _pendingAudioBytes -= seg.bytes;
        [_queueLock unlock];

        // 首个音频段：记录时间轴基准（相对视频首帧归零；视频未到时先按 0）
        if (!_gotFirstAudio) {
            _gotFirstAudio = YES;
            _firstAudioPts = seg.pts;
        }

        // 按样本数推进的段内 pts
        int bytesPerSample = 2 * _audioChannels;
        double segStart = seg.pts - _firstAudioPts;
        if (segStart < 0) {
            segStart = 0;
        }

        CMTime pts = CMTimeMakeWithSeconds(segStart, 600);
        CMTime duration = CMTimeMakeWithSeconds((double)seg.bytes / bytesPerSample / MAX(_audioSampleRate, 1), 600);

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
            status = CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, TRUE,
                                          NULL, NULL, format, seg.bytes / bytesPerSample,
                                          1, &timing, 1, &seg.bytes, &sampleBuffer);
            if (status == noErr && sampleBuffer) {
                if (![_audioInput appendSampleBuffer:sampleBuffer]) {
                    NSLog(@"[RenderRecord] appendSampleBuffer failed");
                }
                CFRelease(sampleBuffer);
            }
            CFRelease(blockBuffer);
        }
        CFRelease(format);
        free(seg.data);
    }
}

- (CVPixelBufferRef)_copyPixelBuffer:(CVPixelBufferRef)src
{
    CVPixelBufferRef dst = NULL;
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

    // 逐 plane 拷贝（兼容 planar/chunky 两种布局）
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

- (void)_feedEncoder
{
    if (!_writer || !_videoInput) {
        return;
    }

    while (_videoInput.isReadyForMoreMediaData) {
        [_queueLock lock];
        if (_pendingCount == 0) {
            [_queueLock unlock];
            break;
        }
        // 取最旧的一帧
        PendingFrame frame = _pending[0];
        memmove(&_pending[0], &_pending[1], sizeof(PendingFrame) * (_pendingCount - 1));
        _pendingCount--;
        [_queueLock unlock];

        if (!_gotFirstFrame) {
            if (isnan(frame.pts)) {
                frame.pts = 0;
            }
            _firstPts = frame.pts;
            _gotFirstFrame = YES;
            [_writer startSessionAtSourceTime:CMTimeMakeWithSeconds(0, 600)];
        }

        // 相对首帧的时间轴
        double rel = frame.pts - _firstPts;
        if (rel < 0) {
            rel = 0;
        }
        CMTime pts = CMTimeMakeWithSeconds(rel, 600);
        if (![_adaptor appendPixelBuffer:frame.pixelBuffer withPresentationTime:pts]) {
            NSLog(@"[RenderRecord] appendPixelBuffer failed: %@", _writer.error);
        }
        CVPixelBufferRelease(frame.pixelBuffer);
    }
}

- (void)stopRecord
{
    if (!_writer) {
        return;
    }
    _stopping = YES;

    // 取出所有未编码的 buffer，避免泄漏（来不及编码的直接丢弃）
    [self _drainPendingBuffers];

    // 局部持有，writer 置 nil 后 block 仍能收尾
    AVAssetWriterInput *input = _videoInput;
    AVAssetWriterInput *audioInput = _audioInput;
    AVAssetWriter *writer = _writer;
    dispatch_queue_t queue = _writerQueue;

    _writer = nil;
    _videoInput = nil;
    _adaptor = nil;
    _audioInput = nil;
    if (_bufferPool) {
        CVPixelBufferPoolRelease(_bufferPool);
        _bufferPool = NULL;
    }

    dispatch_async(queue, ^{
        // 等编码器消化完已入队的帧（requestMediaDataWhenReady 的 block 持有 wself，
        // 而 self 仍被外部持有者引用，此处能正常驱动 _feedEncoder）
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while ([deadline timeIntervalSinceNow] > 0 &&
               writer.status == AVAssetWriterStatusWriting &&
               (input.isReadyForMoreMediaData || audioInput.isReadyForMoreMediaData)) {
            usleep(10 * 1000);
        }
        [input markAsFinished];
        [audioInput markAsFinished];
        [writer finishWritingWithCompletionHandler:^{
            NSLog(@"[RenderRecord] finished, status=%ld, error=%@", (long)writer.status, writer.error);
        }];
    });
}

- (void)_drainPendingBuffers
{
    [_queueLock lock];
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
