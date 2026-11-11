//
//  FSMetalPixelConverter.m
//  FSPlayer
//
//  Created by debugly on 2026/11/10.
//

#import "FSMetalPixelConverter.h"
#import "FSMetalTextureUtils.h"
@import Metal;
@import CoreVideo;

// kernel 名与 FSMetalShaders.metal 中的声明一致
static NSString * const kKernelName = @"fsRecConvertKernel";
// direction 参数值（与 shader 内约定一致）
static const int kDirectionBGRAToNV12 = 0;
static const int kDirectionNV12ToBGRA = 1;

// 纹理描述符：shader 用 float 采样，统一按 unorm 视图包装
static MTLPixelFormat metalFormatOfPlane(OSType fourCC, int plane)
{
    switch (fourCC) {
        case kCVPixelFormatType_32BGRA:
            return MTLPixelFormatBGRA8Unorm;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return plane == 0 ? MTLPixelFormatR8Unorm : MTLPixelFormatRG8Unorm;
        default:
            return MTLPixelFormatInvalid;
    }
}

@interface FSMetalPixelConverter ()
{
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLComputePipelineState> _pipeline;
    CVMetalTextureCacheRef _textureCache;
}
@end

@implementation FSMetalPixelConverter

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                           commandQueue:(id<MTLCommandQueue>)commandQueue
{
    self = [super init];
    if (self) {
        if (!device || !commandQueue) {
            return nil;
        }
        _device = device;
        _commandQueue = commandQueue;

        CVReturn ret = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_textureCache);
        if (ret != kCVReturnSuccess) {
            return nil;
        }

        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSURL *libURL = [bundle URLForResource:@"default" withExtension:@"metallib"];
        NSError *error = nil;
        id<MTLLibrary> library = [_device newLibraryWithFile:libURL.path error:&error];
        if (!library) {
            return nil;
        }
        id<MTLFunction> fn = [library newFunctionWithName:kKernelName];
        if (!fn) {
            return nil;
        }
        _pipeline = [_device newComputePipelineStateWithFunction:fn error:&error];
        if (!_pipeline) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    if (_textureCache) {
        CFRelease(_textureCache);
    }
}

/// 把 CVPixelBuffer 的一个平面包装成可读/写的 Metal 纹理。
/// 返回 MTLTexture（生命周期由 CVMetalTextureRef 保证，存进 outHolder）。
- (id<MTLTexture>)wrapPlane:(CVPixelBufferRef)pb
                      plane:(int)plane
                     format:(MTLPixelFormat)format
                     holder:(NSMutableArray *)outHolder
{
    CVMetalTextureRef texRef = NULL;
    // NV12 是 biplanar：CVPixelBufferGetWidth 返回 Y 宽度，UV 平面取半；
    // 单平面格式（BGRA）始终全尺寸
    BOOL planar = CVPixelBufferGetPlaneCount(pb) > 1;
    size_t width = planar && plane == 1 ? CVPixelBufferGetWidth(pb) / 2 : CVPixelBufferGetWidth(pb);
    size_t height = planar && plane == 1 ? CVPixelBufferGetHeight(pb) / 2 : CVPixelBufferGetHeight(pb);
    CVReturn ret = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, pb,
                                                             NULL, format, width, height, plane, &texRef);
    if (ret != kCVReturnSuccess || !texRef) {
        return nil;
    }
    id<MTLTexture> texture = CVMetalTextureGetTexture(texRef);
    // holder 持有 CVMetalTextureRef（桥接对象），保证纹理后备存储存活到本帧转换结束
    [outHolder addObject:(__bridge_transfer id)texRef];
    return texture;
}

- (BOOL)convert:(CVPixelBufferRef)src to:(CVPixelBufferRef)dst
{
    if (!src || !dst || !_pipeline) {
        return NO;
    }
    OSType srcFmt = CVPixelBufferGetPixelFormatType(src);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(dst);

    BOOL srcIsBGRA = (srcFmt == kCVPixelFormatType_32BGRA);
    BOOL srcIsNV12 = (srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                      srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    BOOL dstIsBGRA = (dstFmt == kCVPixelFormatType_32BGRA);
    BOOL dstIsNV12 = (dstFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                      dstFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

    int direction;
    if (srcIsBGRA && dstIsNV12) {
        direction = kDirectionBGRAToNV12;
    } else if (srcIsNV12 && dstIsBGRA) {
        direction = kDirectionNV12ToBGRA;
    } else {
        return NO; // 同格式走拷贝路径，不经过这里
    }

    NSMutableArray *holders = [NSMutableArray array];
    id<MTLTexture> t0 = nil, t1 = nil, t2 = nil, t3 = nil, t4 = nil;

    if (direction == kDirectionBGRAToNV12) {
        t0 = [self wrapPlane:src plane:0 format:MTLPixelFormatBGRA8Unorm holder:holders];
        t3 = [self wrapPlane:dst plane:0 format:MTLPixelFormatR8Unorm holder:holders];
        t4 = [self wrapPlane:dst plane:1 format:MTLPixelFormatRG8Unorm holder:holders];
    } else {
        t0 = [self wrapPlane:src plane:0 format:MTLPixelFormatR8Unorm holder:holders];
        t1 = [self wrapPlane:src plane:1 format:MTLPixelFormatRG8Unorm holder:holders];
        t2 = [self wrapPlane:dst plane:0 format:MTLPixelFormatBGRA8Unorm holder:holders];
    }
    if (!t0 || !t2 || !(t3 && t4) || (direction == kDirectionNV12ToBGRA && !t1)) {
        return NO;
    }

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_pipeline];
    [enc setTexture:t0 atIndex:0];
    [enc setTexture:t1 atIndex:1];
    [enc setTexture:t2 atIndex:2];
    [enc setTexture:t3 atIndex:3];
    [enc setTexture:t4 atIndex:4];
    [enc setBytes:&direction length:sizeof(direction) atIndex:0];

    // 网格 = 色度分辨率（每线程一个 2x2 块）
    NSUInteger cw = (NSUInteger)(CVPixelBufferGetWidth(dst) + 1) / 2;
    NSUInteger ch = (NSUInteger)(CVPixelBufferGetHeight(dst) + 1) / 2;
    // BGRA→BGRA 不会走到这里；NV12→BGRA 时以 Y 平面（dst BGRA）为准，上面已按 dst 算，一致
    MTLSize grid = MTLSizeMake(cw, ch, 1);
    NSUInteger w = _pipeline.threadExecutionWidth;
    NSUInteger h = _pipeline.maxTotalThreadsPerThreadgroup / w;
    MTLSize tg = MTLSizeMake(w, h, 1);
    [enc dispatchThreads:grid threadsPerThreadgroup:tg];
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];

    if (cmd.status == MTLCommandBufferStatusError) {
        return NO;
    }
    return YES;
}

@end
