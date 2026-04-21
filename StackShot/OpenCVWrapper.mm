//
//  OpenCVWrapper.mm
//  StackShot
//
//  Objective-C++ implementation. The `.mm` extension is what makes the
//  compiler treat this file as Objective-C++, allowing us to mix `#import`
//  with `<opencv2/...>` C++ headers.
//
//  Memory-management contract (this file is hot — called per captured frame):
//    • Every `CVPixelBufferLockBaseAddress` is paired with an unlock via an
//      RAII guard, even on early returns / exceptions.
//    • Every `cv::Mat` we hand out is wrapped in an `OpenCVMat` whose dealloc
//      frees the matrix. We never let raw `cv::Mat` escape an autorelease
//      scope.
//    • CGImage backing storage is owned by a heap-allocated `cv::Mat` whose
//      lifetime is tied to the CGDataProvider release callback — no copies,
//      no leaks.
//

#import "OpenCVWrapper.h"

// OpenCV must be imported *after* the Apple headers above; otherwise the
// `NO` / `YES` / `BOOL` macros from <objc/objc.h> can collide with enum
// values in OpenCV's C++ headers. Wrapping in a push/pop block is the
// standard defensive pattern.
#pragma push_macro("NO")
#pragma push_macro("YES")
#pragma push_macro("BOOL")
#undef NO
#undef YES
#undef BOOL
#import <opencv2/opencv.hpp>
#import <opencv2/imgproc.hpp>
#pragma pop_macro("BOOL")
#pragma pop_macro("YES")
#pragma pop_macro("NO")

#pragma mark - OpenCVMat (opaque cv::Mat holder)

@interface OpenCVMat () {
@public
    cv::Mat _mat;
}
- (instancetype)initWithMat:(cv::Mat &&)mat NS_DESIGNATED_INITIALIZER;
@end

@implementation OpenCVMat

- (instancetype)initWithMat:(cv::Mat &&)mat {
    if ((self = [super init])) {
        _mat = std::move(mat);
    }
    return self;
}

- (void)dealloc {
    // cv::Mat uses internal refcounting; assigning an empty Mat decrements
    // the refcount and releases the pixel buffer when it hits zero.
    _mat.release();
}

- (NSInteger)width    { return _mat.cols; }
- (NSInteger)height   { return _mat.rows; }
- (NSInteger)channels { return _mat.channels(); }

@end

#pragma mark - RAII helper for CVPixelBufferLockBaseAddress

namespace {

struct PixelBufferLock {
    CVPixelBufferRef buffer;
    CVPixelBufferLockFlags flags;
    bool locked;

    PixelBufferLock(CVPixelBufferRef b, CVPixelBufferLockFlags f) noexcept
        : buffer(b), flags(f), locked(false) {
        if (CVPixelBufferLockBaseAddress(buffer, flags) == kCVReturnSuccess) {
            locked = true;
        }
    }
    ~PixelBufferLock() {
        if (locked) {
            CVPixelBufferUnlockBaseAddress(buffer, flags);
        }
    }
    PixelBufferLock(const PixelBufferLock &) = delete;
    PixelBufferLock &operator=(const PixelBufferLock &) = delete;
};

} // namespace

#pragma mark - OpenCVWrapper

@implementation OpenCVWrapper

+ (NSString *)openCVVersion {
    return [NSString stringWithUTF8String:CV_VERSION];
}

#pragma mark CVPixelBuffer ➜ cv::Mat

+ (nullable OpenCVMat *)matFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (pixelBuffer == NULL) { return nil; }

    const OSType fmt = CVPixelBufferGetPixelFormatType(pixelBuffer);

    // We always lock read-only; SCK frames are immutable from our side.
    PixelBufferLock lock(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (!lock.locked) { return nil; }

    const size_t width  = CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    if (width == 0 || height == 0) { return nil; }

    static int pixelBufferLogCount = 0;
    if (pixelBufferLogCount < 3) {
        NSLog(@"🟢 OpenCVWrapper.matFromPixelBuffer 收到像素缓冲: %zux%zu fmt=%u",
              width,
              height,
              (unsigned int)fmt);
        pixelBufferLogCount += 1;
    }

    cv::Mat bgr;

    switch (fmt) {

        // -------- 32BGRA (one plane) ----------------------------------
        case kCVPixelFormatType_32BGRA: {
            void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
            const size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
            if (base == NULL) { return nil; }

            // Wrap the locked buffer *without copying*, then convert to BGR
            // (which clones into freshly-allocated, owned storage).
            cv::Mat bgra((int)height, (int)width, CV_8UC4, base, stride);
            cv::cvtColor(bgra, bgr, cv::COLOR_BGRA2BGR);
            break;
        }

        // -------- NV12 biplanar 4:2:0 (Apple Silicon native) ----------
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: {
            void  *yBase  = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
            void  *uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
            const size_t yStride  = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
            const size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
            const size_t uvWidth  = CVPixelBufferGetWidthOfPlane (pixelBuffer, 1);
            const size_t uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
            if (yBase == NULL || uvBase == NULL) { return nil; }

            cv::Mat yPlane ((int)height,   (int)width,   CV_8UC1, yBase,  yStride);
            cv::Mat uvPlane((int)uvHeight, (int)uvWidth, CV_8UC2, uvBase, uvStride);

            const int code = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                ? cv::COLOR_YUV2BGR_NV12   // full-range is close enough for our use
                : cv::COLOR_YUV2BGR_NV12;
            cv::cvtColorTwoPlane(yPlane, uvPlane, bgr, code);
            break;
        }

        default:
            // Unsupported format — bail out cleanly so the caller can fall
            // back to a slower path.
            return nil;
    }

    // PixelBufferLock unlocks here, but `bgr` already owns its own storage.
    return [[OpenCVMat alloc] initWithMat:std::move(bgr)];
}

#pragma mark cv::Mat ➜ CGImageRef

// Heap-allocated holder whose lifetime is bound to the CGImage's
// CGDataProvider. CoreGraphics calls the release callback below when the
// last CGImage reference is dropped, freeing the underlying cv::Mat.
namespace {
struct MatHolder { cv::Mat mat; };
}

static void OpenCVWrapperReleaseHolder(void *info,
                                       const void * /*data*/,
                                       size_t /*size*/) {
    delete static_cast<MatHolder *>(info);
}

+ (nullable CGImageRef)cgImageFromMat:(OpenCVMat *)matObj CF_RETURNS_RETAINED {
    if (matObj == nil || matObj->_mat.empty()) { return NULL; }

    // Normalize to an 8-bit RGBA layout that CoreGraphics likes.
    // Doing this once here means SwiftUI never sees BGR-vs-RGB confusion.
    auto *holder = new MatHolder();
    const cv::Mat &src = matObj->_mat;

    switch (src.channels()) {
        case 1:
            cv::cvtColor(src, holder->mat, cv::COLOR_GRAY2RGBA);
            break;
        case 3:
            cv::cvtColor(src, holder->mat, cv::COLOR_BGR2RGBA);
            break;
        case 4:
            cv::cvtColor(src, holder->mat, cv::COLOR_BGRA2RGBA);
            break;
        default:
            delete holder;
            return NULL;
    }

    // Make sure rows are contiguous — CGImage assumes a single bytesPerRow.
    if (!holder->mat.isContinuous()) {
        holder->mat = holder->mat.clone();
    }

    const size_t width        = static_cast<size_t>(holder->mat.cols);
    const size_t height       = static_cast<size_t>(holder->mat.rows);
    const size_t bytesPerRow  = holder->mat.step[0];
    const size_t totalBytes   = bytesPerRow * height;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) { delete holder; return NULL; }

    // Zero-copy: the CGDataProvider reads directly out of holder->mat. The
    // release callback frees the holder when CoreGraphics is done.
    CGDataProviderRef provider = CGDataProviderCreateWithData(
        /* info     */ holder,
        /* data     */ holder->mat.data,
        /* size     */ totalBytes,
        /* release  */ &OpenCVWrapperReleaseHolder
    );
    if (provider == NULL) {
        CGColorSpaceRelease(colorSpace);
        delete holder;
        return NULL;
    }

    const CGBitmapInfo bitmapInfo =
        kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast;

    CGImageRef image = CGImageCreate(
        /* width             */ width,
        /* height            */ height,
        /* bitsPerComponent  */ 8,
        /* bitsPerPixel      */ 32,
        /* bytesPerRow       */ bytesPerRow,
        /* colorSpace        */ colorSpace,
        /* bitmapInfo        */ bitmapInfo,
        /* provider          */ provider,
        /* decode            */ NULL,
        /* shouldInterpolate */ false,
        /* intent            */ kCGRenderingIntentDefault
    );

    // Both colorspace and provider are retained by the CGImage — we drop
    // our local references regardless of whether creation succeeded.
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);

    if (image == NULL) {
        // CGImage was never created, so the provider's release callback ran
        // and already freed `holder`. Nothing else to clean up.
        return NULL;
    }
    return image; // CF_RETURNS_RETAINED — caller owns
}

#pragma mark Crop

+ (nullable OpenCVMat *)matByCropping:(OpenCVMat *)source
                              toRect:(CGRect)pixelRect
{
    if (source == nil || source->_mat.empty()) { return nil; }

    static int cropLogCount = 0;
    if (cropLogCount < 3) {
        NSLog(@"🟢 OpenCVWrapper.matByCropping 收到区域(px): %@",
              NSStringFromCGRect(pixelRect));
        cropLogCount += 1;
    }

    cv::Rect roi(
        (int)std::round(pixelRect.origin.x),
        (int)std::round(pixelRect.origin.y),
        (int)std::round(pixelRect.size.width),
        (int)std::round(pixelRect.size.height)
    );
    roi &= cv::Rect(0, 0, source->_mat.cols, source->_mat.rows);
    if (roi.width <= 0 || roi.height <= 0) { return nil; }

    // Deep-copy the ROI: callers persist this Mat across frames, while the
    // original Mat (backed by a transient SCK pixel buffer) may go away.
    cv::Mat cropped = source->_mat(roi).clone();
    return [[OpenCVMat alloc] initWithMat:std::move(cropped)];
}

@end

#pragma mark - VerticalScrollStitcher

//
//  滚动长图拼接 —— 算法纲要
//  ===========================
//  1. 把每一帧转成单通道灰度，仅取“活动区域”（去掉顶部 headerRatio、
//     底部 footerRatio 的固定 UI），用作位移估计的输入。
//  2. 用 cv::phaseCorrelate(prevActive, currActive) 求出当前帧相对上
//     一帧在 (x, y) 上的亚像素位移；同时拿到响应值 response (0~1)，
//     用于判断这次估计是否可信。
//  3. 我们只关心 dy：dy>0 表示上一帧整体向下漂移 → 即用户把页面向上
//     滚动了 dy 像素，新内容从下方进入。
//  4. 把当前帧的“底部新出现的 dy 行”（位于 [activeBottom - dy,
//     activeBottom)）裁出来，追加到全局长图 _canvas 的底部。
//     —— 注意：追加用的是 *当前帧* 的活动区域底部，而不是上一帧；
//        canvas 的顶部仍保留首帧完整截图（含 header），以维持视觉
//        上下文。footer 永远不被追加，避免在长图中段出现 tab bar。
//  5. 残留状态：保存当前帧的灰度活动区域作为下一轮 prev；同时保存
//     当前帧的彩色版本（用于下次裁切新增的 dy 行）。
//

@interface VerticalScrollStitcher () {
    cv::Mat _canvas;          // 已拼接的全局彩色长图（BGR）
    cv::Mat _prevActiveGray;  // 上一帧活动区域的灰度图（用于相位相关）
    cv::Mat _prevFrameBGR;    // 上一帧完整彩色图（备用，目前未直接使用）
    int     _frameWidth;      // 锁定的帧宽度（不允许中途变化）
    int     _frameHeight;     // 锁定的帧高度
    int     _headerPx;        // 顶部冻结像素数
    int     _footerPx;        // 底部冻结像素数
    double  _residualY;       // 亚像素残差累计：phaseCorrelate 给的是浮点
                              // dy，整像素裁切后剩下的小数堆在这里，避免
                              // 长距离滚动时累计漂移。
}
@end

@implementation VerticalScrollStitcher

- (instancetype)init {
    if ((self = [super init])) {
        _headerRatio   = 0.10;
        _footerRatio   = 0.10;
        _minResponse   = 0.10;
        _frameWidth    = 0;
        _frameHeight   = 0;
        _headerPx      = 0;
        _footerPx      = 0;
        _residualY     = 0.0;
        _framesProcessed = 0;
    }
    return self;
}

- (NSInteger)canvasHeight { return _canvas.rows; }

- (void)reset {
    _canvas.release();
    _prevActiveGray.release();
    _prevFrameBGR.release();
    _frameWidth = 0;
    _frameHeight = 0;
    _headerPx = 0;
    _footerPx = 0;
    _residualY = 0.0;
    _framesProcessed = 0;
}

#pragma mark Core entry

- (StitchFrameResult)addFrame:(OpenCVMat *)frame
                    outDeltaY:(double *)outDeltaY
{
    if (outDeltaY) { *outDeltaY = 0.0; }
    if (frame == nil || frame->_mat.empty()) {
        return StitchFrameResultRejected;
    }

    cv::Mat current = frame->_mat;   // 浅引用，引用计数 +1
    // 统一为 3 通道 BGR；若上游给的是 BGRA / Gray，转成 BGR 再处理。
    if (current.channels() == 4) {
        cv::Mat tmp; cv::cvtColor(current, tmp, cv::COLOR_BGRA2BGR); current = tmp;
    } else if (current.channels() == 1) {
        cv::Mat tmp; cv::cvtColor(current, tmp, cv::COLOR_GRAY2BGR); current = tmp;
    }

    _framesProcessed += 1;

    // ---- 第一帧：作为长图的基线 ----
    if (_canvas.empty()) {
        _frameWidth  = current.cols;
        _frameHeight = current.rows;
        [self recomputeFrozenStrips];

        // 整张首帧入画（含 header / footer），用户看到的长图开头与
        // 当前窗口完全一致，体验上最自然。
        _canvas = current.clone();
        _prevActiveGray = [self extractActiveGray:current];
        _prevFrameBGR = current.clone();
        return StitchFrameResultAccepted;
    }

    // ---- 后续帧：尺寸必须严格一致，否则视为目标窗口被 resize，丢弃 ----
    if (current.cols != _frameWidth || current.rows != _frameHeight) {
        return StitchFrameResultRejected;
    }

    // ---- 相位相关求亚像素位移 ----
    cv::Mat currActiveGray = [self extractActiveGray:current];

    double response = 0.0;
    // phaseCorrelate 要求 32F/64F 单通道；extractActiveGray 已转为 32F。
    cv::Point2d shift = cv::phaseCorrelate(
        _prevActiveGray, currActiveGray,
        cv::noArray(),  // 不带窗口 → 我们已自己加了 Hanning（见下）
        &response
    );

    // shift = (dx, dy)：表示 currActiveGray 相对 prevActiveGray 的偏移。
    //   • 若用户把页面向上拖（内容上移、新内容从下方进入），
    //     prev 的特征会出现在 curr 的更高位置（行号减小），
    //     phaseCorrelate 返回 dy < 0。
    //   • 我们要追加的“新出现的行数”取 -dy 的整数部分。
    double dyFloat = -shift.y + _residualY;
    int    dyInt   = (int)std::round(dyFloat);

    if (outDeltaY) { *outDeltaY = dyFloat; }

    // 置信度 / 几何合理性双重门：
    //   - response 太低，说明两帧之间没有足够的纹理重合（可能整页刷新）；
    //   - |dx| 太大，说明发生了水平抖动 / 切换页面，不应拼接。
    const int activeHeight = _frameHeight - _headerPx - _footerPx;
    if (response < _minResponse) {
        return StitchFrameResultRejected;
    }
    if (std::abs(shift.x) > _frameWidth * 0.02) {  // 允许 ≤2% 宽度的横向漂移
        return StitchFrameResultRejected;
    }

    // 用户没动 / 抖动过小：保留 prev 不更新（更新会让噪声逐帧累计），
    // 但残差累加进 _residualY，下一帧再合并判断。
    if (dyInt <= 0) {
        _residualY = dyFloat;  // 可能是负的微小漂移，留待下次抵消
        return StitchFrameResultNoMotion;
    }

    // 反向 / 过大位移：极可能是误匹配（例如周期性纹理导致整周期跳变）。
    // 单次最多接受 “活动区域高度” 的位移；超出的丢弃。
    if (dyInt > activeHeight) {
        return StitchFrameResultRejected;
    }

    // ---- 裁切“新出现的 dy 行” ----
    //
    // 坐标推导（以当前帧为参照系，y 轴向下，origin = 左上角）：
    //   activeTop    = _headerPx
    //   activeBottom = _frameHeight - _footerPx          （exclusive）
    //   新增 dy 行位于：[activeBottom - dyInt, activeBottom)
    //
    // 解释：用户向上滚动 dy 像素后，原本处在 footer 上沿之上的内容已
    // 被 footer 遮住；而此前位于 activeBottom - dy 处的像素，正是这
    // 一帧首次出现的“下一段内容”。我们恰好取这 dy 行追加。
    const int sliceTop    = (_frameHeight - _footerPx) - dyInt;
    const int sliceBottom = (_frameHeight - _footerPx);
    cv::Rect sliceRect(0, sliceTop, _frameWidth, sliceBottom - sliceTop);

    // 安全裁剪：sliceRect 与帧边界求交，防御任何边界数值误差。
    sliceRect &= cv::Rect(0, 0, current.cols, current.rows);
    if (sliceRect.height <= 0 || sliceRect.width <= 0) {
        return StitchFrameResultRejected;
    }
    cv::Mat slice = current(sliceRect);

    // ---- 追加到 canvas 底部 ----
    //
    // 直接 vconcat 会在内部分配新缓冲并整体拷贝旧 canvas，对长图来说
    // 性能可接受（每帧只多拷贝一次旧图），逻辑也最简单。如果将来要
    // 支持极长图（>20k 行），可以换成预分配 + 指针游标的环形增长策略。
    cv::Mat newCanvas;
    cv::vconcat(_canvas, slice, newCanvas);
    _canvas = newCanvas;

    // ---- 更新参考帧与残差 ----
    _prevActiveGray = currActiveGray;          // 已是 deep copy（cvtColor 输出）
    _prevFrameBGR   = current.clone();
    _residualY      = dyFloat - (double)dyInt; // 把整像素吃掉，留小数部分

    return StitchFrameResultAppended;
}

- (nullable OpenCVMat *)stitchedImage {
    if (_canvas.empty()) { return nil; }
    cv::Mat copy = _canvas.clone();           // 深拷贝，防止外部并发使用时撞到下一帧追加
    return [[OpenCVMat alloc] initWithMat:std::move(copy)];
}

#pragma mark Internals

/// 根据当前 headerRatio / footerRatio 重新计算冻结条带的像素高度。
/// clamp 到 [0, 0.45] 防止活动区域被吃光。
- (void)recomputeFrozenStrips {
    const double hr = std::max(0.0, std::min(0.45, _headerRatio));
    const double fr = std::max(0.0, std::min(0.45, _footerRatio));
    _headerPx = (int)std::round(_frameHeight * hr);
    _footerPx = (int)std::round(_frameHeight * fr);
    // 至少留 32 像素的活动区域，否则相位相关无意义。
    const int active = _frameHeight - _headerPx - _footerPx;
    if (active < 32) {
        _headerPx = 0;
        _footerPx = 0;
    }
}

/// 提取活动区域（去掉顶部固定栏与底部 tab bar），转灰度并转 32F，
/// 同时乘上 Hann 窗以抑制相位相关的边缘效应。
- (cv::Mat)extractActiveGray:(const cv::Mat &)frameBGR {
    [self recomputeFrozenStrips];

    cv::Rect activeRect(
        0,
        _headerPx,
        frameBGR.cols,
        frameBGR.rows - _headerPx - _footerPx
    );
    activeRect &= cv::Rect(0, 0, frameBGR.cols, frameBGR.rows);
    cv::Mat active = frameBGR(activeRect);

    cv::Mat gray;
    cv::cvtColor(active, gray, cv::COLOR_BGR2GRAY);

    cv::Mat gray32;
    gray.convertTo(gray32, CV_32F, 1.0 / 255.0);

    // Hanning 窗：phaseCorrelate 内部假设输入是周期信号，未加窗时
    // 图像四边的高频跳变会污染频谱，导致响应值偏低甚至误匹配。
    cv::Mat hann;
    cv::createHanningWindow(hann, gray32.size(), CV_32F);
    cv::Mat windowed;
    cv::multiply(gray32, hann, windowed);

    return windowed;
}

@end
