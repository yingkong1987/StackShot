//
//  OpenCVWrapper.h
//  StackShot
//
//  Pure Objective-C facade around the OpenCV (C++) APIs so that Swift can
//  consume them through the bridging header without ever importing C++.
//
//  IMPORTANT: This header MUST stay free of any C++ symbols (no `cv::`,
//  no `<opencv2/...>` includes). All C++ usage lives in OpenCVWrapper.mm.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Opaque handle representing an underlying `cv::Mat`. The handle owns the
/// matrix and must be released with `-[OpenCVWrapper releaseMat:]` (or simply
/// let ARC drop the last strong reference — the dealloc frees the C++ object).
///
/// We expose the matrix as an opaque `NSObject` so Swift code can hold onto
/// intermediate processing results (e.g. the in-progress stitched long image)
/// without ever touching C++ types.
@interface OpenCVMat : NSObject
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) NSInteger channels;
@end

@interface OpenCVWrapper : NSObject

/// Returns the linked OpenCV version (useful for sanity-checking the build).
+ (NSString *)openCVVersion;

#pragma mark - CVPixelBuffer ➜ cv::Mat

/// Converts a `CVPixelBufferRef` produced by ScreenCaptureKit into an
/// `OpenCVMat` (BGR, 8-bit, 3 channels — the canonical OpenCV layout).
///
/// Supported source formats (the two Apple-Silicon-friendly ones SCK emits):
///   • `kCVPixelFormatType_32BGRA`
///   • `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`  (NV12)
///   • `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12)
///
/// The returned `OpenCVMat` owns its pixel storage, so the caller is free to
/// release the source `CVPixelBuffer` immediately after this call returns.
/// Returns `nil` if the pixel format is unsupported or locking fails.
+ (nullable OpenCVMat *)matFromPixelBuffer:(CVPixelBufferRef)pixelBuffer;

#pragma mark - cv::Mat ➜ CGImageRef

/// Converts an `OpenCVMat` (BGR / BGRA / Gray) into a `CGImageRef` ready to
/// be wrapped in `Image(decorative:)` for SwiftUI rendering.
///
/// The returned `CGImageRef` follows the **Create Rule** — the caller owns
/// it and must `CGImageRelease` (or, from Swift, `takeRetainedValue()` when
/// bridging through `Unmanaged`).
+ (nullable CGImageRef)cgImageFromMat:(OpenCVMat *)mat CF_RETURNS_RETAINED;

#pragma mark - Cropping

/// Returns a new `OpenCVMat` containing only the sub-region defined by
/// `pixelRect` (in mat pixel coordinates, origin top-left). The result is a
/// **deep copy** of that ROI — safe to retain after the input is gone.
/// Returns `nil` if the rect is empty or doesn't intersect the source.
+ (nullable OpenCVMat *)matByCropping:(OpenCVMat *)source
                              toRect:(CGRect)pixelRect;

@end

#pragma mark - Vertical scroll stitcher

/// Result of feeding one frame into the stitcher.
typedef NS_ENUM(NSInteger, StitchFrameResult) {
    /// Frame was the very first one — adopted as the base of the canvas.
    StitchFrameResultAccepted,
    /// Frame extended the canvas (user scrolled down by `appendedRows` px).
    StitchFrameResultAppended,
    /// Detected motion was too small to be meaningful (no-op, e.g. user paused).
    StitchFrameResultNoMotion,
    /// Frame was discarded — confidence too low or geometry mismatch.
    /// Caller should keep feeding; the stitcher will try again next frame.
    StitchFrameResultRejected,
};

/// Incremental vertical-scroll stitcher.
///
/// Feed it the BGR frames coming out of `+matFromPixelBuffer:` one by one as
/// the user scrolls. Internally it uses `cv::phaseCorrelate` on the central
/// "active" band (top/bottom strips ignored, see `headerRatio`/`footerRatio`)
/// to recover the per-frame Y displacement, then appends only the new tail
/// rows to a long canvas image.
///
/// Thread-safety: not thread-safe — call `addFrame:` from a single serial
/// queue (e.g. `ScreenCaptureManager`'s `frameQueue`).
@interface VerticalScrollStitcher : NSObject

/// Fraction (0…0.45) of the frame height treated as a frozen header strip
/// and excluded from both motion estimation and the appended slice.
/// Default: 0.10 (10%).
@property (nonatomic) double headerRatio;

/// Fraction (0…0.45) of the frame height treated as a frozen footer strip
/// (e.g. tab bar) and excluded the same way. Default: 0.10 (10%).
@property (nonatomic) double footerRatio;

/// Minimum phase-correlation response (0…1) required to trust a measurement.
/// Lower values accept more frames but risk drift; higher values reject more
/// noisy/transient frames. Default: 0.10.
@property (nonatomic) double minResponse;

/// Number of frames consumed so far (incl. rejected ones).
@property (nonatomic, readonly) NSInteger framesProcessed;

/// Current canvas height in pixels.
@property (nonatomic, readonly) NSInteger canvasHeight;

/// Feed one frame into the stitcher. The frame is **not** retained beyond
/// this call — the stitcher copies what it needs (the previous-frame ROI
/// and any newly appended rows).
///
/// `outDeltaY` is filled with the recovered Y displacement (positive ⇒ user
/// scrolled the content up so the page reveals new rows at the bottom).
/// May be `NULL`.
- (StitchFrameResult)addFrame:(OpenCVMat *)frame
                    outDeltaY:(nullable double *)outDeltaY;

/// Snapshot of the stitched long image, or `nil` if no frame has been
/// accepted yet. The returned `OpenCVMat` is a deep copy — safe to mutate
/// or hand to `+cgImageFromMat:` without affecting further stitching.
- (nullable OpenCVMat *)stitchedImage;

/// Drops all accumulated state so a new stitching session can begin.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
