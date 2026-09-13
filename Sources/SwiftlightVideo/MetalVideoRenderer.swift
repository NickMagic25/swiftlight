import Foundation
import Metal
import QuartzCore
import CoreVideo
import simd

public struct RenderStatistics: Codable, Sendable {
    public var submitted = 0
    public var completed = 0
    public var presented = 0
    public var unconfirmedPresentation = 0
    public var skippedGPUCapacity = 0
    public var inFlight = 0
    public var inFlightHighWater = 0
    public var gpuMilliseconds: [Double] = []
    public var actualPresentationNanoseconds: [UInt64] = []
}
public struct RenderResult: Sendable {
    public let succeeded: Bool
    public let gpuMilliseconds: Double?
}
public enum VideoScaleMode: Sendable { case fit, fill, integer }
public enum RendererFailure: Error, CustomStringConvertible {
    case unavailable(String), unsupportedFormat(OSType), unsupportedColor(String)
    public var description: String {
        switch self {
        case .unavailable(let reason): return reason
        case .unsupportedFormat(let format): return "Unsupported canonical pixel format: \(format)"
        case .unsupportedColor(let reason): return "Unsupported color signaling: \(reason)"
        }
    }
}

/// Strong ownership spans GPU completion, including CoreVideo wrappers. Populated
/// before commit, cleared only by its single completion handler after GPU execution;
/// no other thread accesses fields after commit. MTLTexture alone is insufficient.
private final class TextureLease: @unchecked Sendable {
    private var frame: DecodedFrame?
    private var y: CVMetalTexture?
    private var uv: CVMetalTexture?
    init(frame: DecodedFrame, y: CVMetalTexture, uv: CVMetalTexture) { self.frame = frame; self.y = y; self.uv = uv }
    func releaseAfterGPUCompletion() { uv = nil; y = nil; frame = nil }
}

private struct ShaderUniforms {
    var yScaleOffset: SIMD4<Float>
    var chromaScaleOffset: SIMD4<Float>
    var sampleScale: SIMD4<Float>
    var chromaPosition: SIMD4<Float>
    var sourceOrigin: SIMD4<Float>
    var coefficients: SIMD4<Float>
    var mode: SIMD4<UInt32>
}

/// Encoding/cache access is serialized separately from bounded metrics. No Core
/// Animation or Metal call runs under the metrics lock acquired by callbacks. Drawable
/// registration/presentation and commit also run outside the encoding lock: Core
/// Animation may invoke presented handlers while holding its own drawable lock.
/// No synchronous GPU waits are performed here. SDR/HDR output is extended linear sRGB,
/// where 1.0 represents 203 nits for PQ and SDR reference white for SDR.
public final class MetalVideoRenderer: @unchecked Sendable {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var cache: CVMetalTextureCache
    private var pipelines: [UInt: MTLRenderPipelineState] = [:]
    private let encodingLock = NSLock()
    private let lock = NSLock()
    private var counters = RenderStatistics()
    private let maximumInFlight: Int
    private let idle = DispatchGroup()

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), maximumInFlight: Int = 3) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw RendererFailure.unavailable("Metal device/queue unavailable") }
        self.device = device; self.queue = queue; self.maximumInFlight = max(1, min(maximumInFlight, 3))
        library = try device.makeLibrary(source: Self.shader, options: nil)
        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard status == kCVReturnSuccess, let textureCache else { throw RendererFailure.unavailable("CVMetalTextureCacheCreate: \(status)") }
        cache = textureCache
    }
    public var statistics: RenderStatistics { lock.lock(); defer { lock.unlock() }; return counters }
    /// Correctness/teardown diagnostic only; the display path never calls this.
    public func waitUntilIdleForValidation(timeoutSeconds: Double = 10) throws {
        guard idle.wait(timeout: .now() + timeoutSeconds) == .success else { throw RendererFailure.unavailable("GPU completion timeout") }
    }

    /// Uses the display-link supplied drawable. A nil/missing drawable is handled by
    /// the surface before taking the latest frame. No second drawable is acquired.
    @discardableResult
    public func render(_ frame: DecodedFrame, into drawable: CAMetalDrawable,
                       scaleMode: VideoScaleMode = .fit,
                       completion: (@Sendable (RenderResult) -> Void)? = nil) throws -> Bool {
        try encode(frame, target: drawable.texture, drawable: drawable, present: { $0.present(drawable) }, scaleMode: scaleMode, completion: completion)
    }

    /// Validation uses this exact import, pipeline and shader, with a shared float target.
    public func makeReadbackTarget(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RendererFailure.unavailable("Readback target allocation failed") }
        return texture
    }
    @discardableResult
    public func render(_ frame: DecodedFrame, into target: MTLTexture,
                       scaleMode: VideoScaleMode = .fit,
                       completion: (@Sendable (RenderResult) -> Void)? = nil) throws -> Bool {
        try encode(frame, target: target, drawable: nil, present: nil, scaleMode: scaleMode, completion: completion)
    }

    // Separate the presentation action from callback registration so a deterministic
    // test can exercise the real lock ordering without opening a display surface.
    func encode(_ frame: DecodedFrame, target: MTLTexture, drawable: MTLDrawable?,
                present: ((MTLCommandBuffer) -> Void)?, scaleMode: VideoScaleMode,
                completion: (@Sendable (RenderResult) -> Void)?) throws -> Bool {
        encodingLock.lock()
        var encodingLocked = true
        defer { if encodingLocked { encodingLock.unlock() } }
        lock.lock()
        guard counters.inFlight < maximumInFlight else {
            counters.skippedGPUCapacity += 1; lock.unlock(); return false
        }
        lock.unlock()
        guard target.pixelFormat == .rgba16Float || target.pixelFormat == .rgba32Float else {
            throw RendererFailure.unavailable("Linear floating-point drawable required")
        }
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let tenBit: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: tenBit = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: tenBit = true
        default: throw RendererFailure.unsupportedFormat(format)
        }
        guard CVPixelBufferGetPlaneCount(frame.pixelBuffer) == 2 else { throw RendererFailure.unsupportedFormat(format) }
        guard [UInt16(1), 5, 6, 9].contains(frame.color.matrix), [UInt16(1), 6, 13, 16].contains(frame.color.transfer),
              [UInt16(1), 9].contains(frame.color.primaries) else {
            throw RendererFailure.unsupportedColor("matrix \(frame.color.matrix), transfer \(frame.color.transfer), primaries \(frame.color.primaries)")
        }
        var wrappers: [CVMetalTexture] = []
        var textures: [MTLTexture] = []
        for plane in 0..<2 {
            var wrapper: CVMetalTexture?
            let pixelFormat: MTLPixelFormat = plane == 0 ? (tenBit ? .r16Unorm : .r8Unorm) : (tenBit ? .rg16Unorm : .rg8Unorm)
            let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, frame.pixelBuffer, nil, pixelFormat,
                CVPixelBufferGetWidthOfPlane(frame.pixelBuffer, plane), CVPixelBufferGetHeightOfPlane(frame.pixelBuffer, plane), plane, &wrapper)
            guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
                throw RendererFailure.unavailable("CoreVideo Metal plane \(plane) import failed: \(status)")
            }
            wrappers.append(wrapper); textures.append(texture)
        }
        let lease = TextureLease(frame: frame, y: wrappers[0], uv: wrappers[1])
        let pipeline: MTLRenderPipelineState
        if let cached = pipelines[target.pixelFormat.rawValue] { pipeline = cached }
        else {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "videoFragment")
            descriptor.colorAttachments[0].pixelFormat = target.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[target.pixelFormat.rawValue] = pipeline
        }
        let denominator: Float = tenBit ? 65535.0 / 64.0 : 255
        let codeMax: Float = tenBit ? 1023 : 255
        let low: Float = frame.color.fullRange ? 0 : (tenBit ? 64 : 16)
        let span: Float = frame.color.fullRange ? codeMax : (tenBit ? 876 : 219)
        let chromaSpan: Float = frame.color.fullRange ? codeMax : (tenBit ? 896 : 224)
        let chromaCenter: Float = tenBit ? 512 : 128
        let kr: Float = frame.color.matrix == 9 ? 0.2627 : ([5, 6].contains(frame.color.matrix) ? 0.299 : 0.2126)
        let kb: Float = frame.color.matrix == 9 ? 0.0593 : ([5, 6].contains(frame.color.matrix) ? 0.114 : 0.0722)
        let location = frame.color.chromaLocation
        let shiftX: Float = [UInt8(0), 2, 4].contains(location) ? 0.5 : 0
        let shiftY: Float = [UInt8(2), 3].contains(location) ? 0.5 : ([UInt8(4), 5].contains(location) ? -0.5 : 0)
        var source = frame.contentRect
        if scaleMode == .fill {
            let ratio = CGFloat(target.width) / CGFloat(target.height)
            if source.width / source.height > ratio {
                let width = source.height * ratio; source.origin.x += (source.width - width) / 2; source.size.width = width
            } else {
                let height = source.width / ratio; source.origin.y += (source.height - height) / 2; source.size.height = height
            }
        }
        var uniforms = ShaderUniforms(
            yScaleOffset: SIMD4(denominator / span, -low / span, 0, 0),
            chromaScaleOffset: SIMD4(denominator / chromaSpan, -chromaCenter / chromaSpan, 0, 0),
            sampleScale: SIMD4(Float(source.width) / Float(textures[0].width), Float(source.height) / Float(textures[0].height),
                Float(source.width) / Float(textures[1].width * 2), Float(source.height) / Float(textures[1].height * 2)),
            chromaPosition: SIMD4(shiftX / Float(textures[1].width * 2), shiftY / Float(textures[1].height * 2), 0, 0),
            sourceOrigin: SIMD4(Float(source.minX) / Float(textures[0].width), Float(source.minY) / Float(textures[0].height),
                Float(source.minX) / Float(textures[1].width * 2), Float(source.minY) / Float(textures[1].height * 2)),
            coefficients: SIMD4(kr, kb, 0, 0), mode: SIMD4(UInt32(frame.color.transfer), UInt32(frame.color.primaries), 0, 0))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererFailure.unavailable("Metal command allocation failed")
        }
        let fit = min(Double(target.width) / Double(source.width), Double(target.height) / Double(source.height))
        let scale = scaleMode == .integer && fit >= 1 ? floor(fit) : fit
        let width = Double(source.width) * scale, height = Double(source.height) * scale
        encoder.setViewport(MTLViewport(originX: (Double(target.width) - width) / 2, originY: (Double(target.height) - height) / 2,
            width: width, height: height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(textures[0], index: 0); encoder.setFragmentTexture(textures[1], index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        lock.lock()
        counters.submitted += 1; counters.inFlight += 1; counters.inFlightHighWater = max(counters.inFlightHighWater, counters.inFlight)
        lock.unlock()
        idle.enter()
        // Preserve command ordering for concurrent callers before releasing encoding
        // serialization. No callback can need this lock, and metrics are unlocked.
        command.enqueue()
        encodingLock.unlock(); encodingLocked = false
        if let drawable {
            drawable.addPresentedHandler { [weak self] presented in
                guard let self else { return }
                let presentedTime = presented.presentedTime
                self.lock.lock(); defer { self.lock.unlock() }
                guard presentedTime.isFinite, presentedTime > 0 else {
                    self.counters.unconfirmedPresentation += 1; return
                }
                self.counters.presented += 1
                if self.counters.actualPresentationNanoseconds.count == 1024 { self.counters.actualPresentationNanoseconds.removeFirst() }
                self.counters.actualPresentationNanoseconds.append(UInt64(presentedTime * 1_000_000_000))
            }
            present?(command)
        }
        command.addCompletedHandler { [self, lease] command in
            let duration = command.gpuEndTime > command.gpuStartTime ? (command.gpuEndTime - command.gpuStartTime) * 1000 : nil
            self.lock.lock()
            self.counters.completed += 1; self.counters.inFlight -= 1
            if let duration {
                if self.counters.gpuMilliseconds.count == 1024 { self.counters.gpuMilliseconds.removeFirst() }
                self.counters.gpuMilliseconds.append(duration)
            }
            self.lock.unlock()
            withExtendedLifetime(lease) { completion?(RenderResult(succeeded: command.status == .completed, gpuMilliseconds: duration)) }
            lease.releaseAfterGPUCompletion()
            self.idle.leave()
        }
        command.commit()
        return true
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    struct Uniforms { float4 y; float4 c; float4 scale; float4 chroma; float4 origin; float4 coefficients; uint4 mode; };
    vertex Vertex videoVertex(uint id [[vertex_id]]) {
        float2 p = id == 0 ? float2(-1,-1) : (id == 1 ? float2(3,-1) : float2(-1,3));
        return {float4(p,0,1), float2((p.x+1)*0.5, (1-p.y)*0.5)};
    }
    float3 linearize(float3 v, uint transfer) {
        v = max(v, 0.0f);
        if (transfer == 16) {
            constexpr float m1=2610.0/16384.0, m2=2523.0/32.0, c1=3424.0/4096.0, c2=2413.0/128.0, c3=2392.0/128.0;
            float3 p=pow(v, 1.0/m2);
            return pow(max(p-c1,0.0f)/max(c2-c3*p,1e-7f),1.0/m1)*(10000.0/203.0);
        }
        if (transfer == 13) return select(v/12.92,pow((v+0.055)/1.055,2.4),v>0.04045);
        return select(v/4.5,pow((v+0.099)/1.099,1.0/0.45),v>=0.081);
    }
    fragment float4 videoFragment(Vertex input [[stage_in]], texture2d<float> yTex [[texture(0)]],
        texture2d<float> uvTex [[texture(1)]], constant Uniforms& u [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float y = yTex.sample(s,input.uv*u.scale.xy+u.origin.xy).r*u.y.x+u.y.y;
        float2 c = uvTex.sample(s,input.uv*u.scale.zw+u.origin.zw+u.chroma.xy).rg*u.c.x+u.c.y;
        float kr=u.coefficients.x, kb=u.coefficients.y, kg=1-kr-kb;
        float3 rgb=float3(y+2*(1-kr)*c.y, y-2*kb*(1-kb)/kg*c.x-2*kr*(1-kr)/kg*c.y, y+2*(1-kb)*c.x);
        rgb=linearize(rgb,u.mode.x);
        if(u.mode.y == 9) rgb=float3(dot(rgb,float3(1.660491,-0.587641,-0.072850)),
            dot(rgb,float3(-0.124550,1.132900,-0.008349)),dot(rgb,float3(-0.018151,-0.100579,1.118730)));
        return float4(rgb,1);
    }
    """
}
