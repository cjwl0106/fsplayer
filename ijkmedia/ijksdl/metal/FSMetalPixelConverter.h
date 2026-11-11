//
//  FSMetalPixelConverter.h
//  FSPlayer
//
//  Created by debugly on 2026/11/10.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CVPixelBuffer.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Metal GPU 像素格式转换：BGRA ↔ NV12（BT.709 full range）。
/// 供 FSRenderRecorder 在渲染管线格式切换（特效开关 NV12↔BGRA）时把源帧
/// 转成录制格式。相比 CPU 标量转换（720x1280 正向 ~6ms/反向 ~12ms），
/// GPU 路径 <1ms，且不占 feeder 线程的 CPU。
///
/// 用法：一实例一种尺寸/方向组合，convert:to: 失败返回 NO（调用方丢帧）。
/// 线程约束：convert:to: 必须在单一串行队列上调用（内部无锁）。
@interface FSMetalPixelConverter : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                           commandQueue:(id<MTLCommandQueue>)commandQueue;

/// 把 src（BGRA 或 NV12）转换成 dst 的格式并写入（同步，内部 waitUntilCompleted）。
/// 仅支持 BGRA↔NV12（含 video/full range 两种 NV12），其余组合返回 NO。
- (BOOL)convert:(CVPixelBufferRef)src to:(CVPixelBufferRef)dst;

@end

NS_ASSUME_NONNULL_END
