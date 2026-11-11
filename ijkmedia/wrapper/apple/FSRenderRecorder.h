/*
 * FSRenderRecorder.h
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

// 渲染层录制器：把 videoRenderingWillDisplay 处理后的视频帧（CVPixelBuffer）
// 用 AVAssetWriter 硬编重新编码写文件。与 startFastRecord（直录原始码流）互补，
// 用于录制经过代理替换/滤镜处理后的画面。

#import <Foundation/Foundation.h>
#import <CoreVideo/CVPixelBuffer.h>

NS_ASSUME_NONNULL_BEGIN

@interface FSRenderRecorder : NSObject

/// 录制状态
@property(nonatomic, readonly) BOOL recording;

/// 预热录制管线（幂等，进程内只执行一次，重复调用无副作用）：
/// 1. 提前创建共享 Metal 像素转换器（metallib 加载 + kernel 编译，数百 ms）；
/// 2. 用临时文件完整走一遍 AVAssetWriter 编码流程（startWriting + append +
///    finishWriting），预热 VideoToolbox 硬编会话——首次创建编码器会与
///    解码器争抢视频硬件，表现为开始录制时画面卡住一会。
/// pixelBuffer 只用于确定预热的宽高/像素格式（与真实录制一致时硬编会话
/// 复用率最高），不会被持有，可传 nil（只预热 Metal 部分）。全部在后台
/// 线程执行，建议起播出画后尽早调用。
+ (void)warmUpResourcesWithPixelBuffer:(nullable CVPixelBufferRef)pixelBuffer
                                   fps:(float)fps
                       audioSampleRate:(int)audioSampleRate
                         audioChannels:(int)audioChannels;

/// 启动录制。pixelBuffer 仅用于确定视频尺寸与像素格式，不会被持有。
/// audioSampleRate/audioChannels 为播放输出的音频参数（>0 时预建音频轨；
/// 0 表示无音频或参数未知，只录视频）。
/// @return 成功返回 0
- (int)startRecord:(NSString *)filePath
       pixelBuffer:(CVPixelBufferRef)pixelBuffer
               fps:(float)fps
       audioSampleRate:(int)audioSampleRate
      audioChannels:(int)audioChannels
          metadata:(nullable NSDictionary<NSString *, NSString *> *)metadata;

/// 追加一帧。pts 为帧的显示时间戳（秒），未知时传 NAN（内部按 fps 递增）。
/// 内部会立即拷贝像素并异步编码，不会阻塞调用线程；队列满时丢帧。
- (void)appendPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(double)pts;

/// 追加一段 PCM（S16 交错格式，与播放输出一致）。pts 为本段首个样本的时间戳（秒）。
/// samples 为 NULL 且 nbSamples < 0 时表示 flush（seek 等），丢弃未编码音频。
- (void)appendAudioSamples:(const int16_t *)samples
                nbSamples:(int)nbSamples
               sampleRate:(int)sampleRate
                 channels:(int)channels
                      pts:(double)pts;

/// 停止录制并等待写完文件尾。异步完成。
/// completion 在文件完全写完（moov 已落盘，可直接保存/移动）后回调一次；
/// error 非空表示写入失败。传 NULL 则只打日志（与旧行为一致）。
- (void)stopRecordWithCompletion:(nullable void (^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
