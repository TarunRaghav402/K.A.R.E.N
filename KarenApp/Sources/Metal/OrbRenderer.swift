import Metal
import MetalKit
import simd

// ─── OrbRenderer is only active in Xcode/Metal builds ────────────────────────
// When CANVAS_RENDERER is defined (swift build without metal compiler),
// this file compiles but the renderer is not instantiated.

// ─── Orb Uniforms (matches Metal shader) ─────────────────────────────────────

struct OrbUniforms {
    var modelMatrix:     simd_float4x4 = matrix_identity_float4x4
    var viewProjection:  simd_float4x4 = matrix_identity_float4x4
    var time:            Float = 0
    var audioLevel:      Float = 0
    var orbStateInt:     Int32 = 0
    var zoom:            Float = 1
    var yaw:             Float = 0
    var pitch:           Float = 0
    var lodLevel:        Float = 0
    var reduceMotion:    Float = 0
    var pad:             simd_float2 = .zero
}

// ─── MTKView Renderer ─────────────────────────────────────────────────────────

final class OrbRenderer: NSObject, MTKViewDelegate {

    weak var core: KarenCore?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var startTime = Date()

    // Pipeline states
    private var starPSO:      MTLRenderPipelineState?
    private var filamentPSO:  MTLRenderPipelineState?
    private var ringPSO:      MTLRenderPipelineState?
    private var corePSO:      MTLRenderPipelineState?

    private var uniformBuffer: MTLBuffer?
    private let filamentCount = 8192
    private let ringSegments  = 256
    private let ringCount     = 3

    init?(device: MTLDevice, core: KarenCore) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.core = core
        super.init()
        buildPipelines()
        uniformBuffer = device.makeBuffer(length: MemoryLayout<OrbUniforms>.stride, options: .storageModeShared)
    }

    private func buildPipelines() {
        guard let lib = try? device.makeDefaultLibrary(bundle: .main) else {
            print("[OrbRenderer] ⚠️ Metal library not found — install Xcode and rebuild")
            return
        }

        func pso(vert: String, frag: String,
                 blend: Bool = true,
                 topo: MTLPrimitiveTopologyClass = .triangle) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction   = lib.makeFunction(name: vert)
            d.fragmentFunction = lib.makeFunction(name: frag)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.inputPrimitiveTopology = topo
            if blend {
                let ca = d.colorAttachments[0]!
                ca.isBlendingEnabled = true
                ca.sourceRGBBlendFactor      = .sourceAlpha
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.sourceAlphaBlendFactor    = .one
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }

        starPSO     = pso(vert: "star_vert",     frag: "star_frag",     blend: false)
        filamentPSO = pso(vert: "filament_vert", frag: "filament_frag",
                          blend: true, topo: .point)
        ringPSO     = pso(vert: "ring_vert",     frag: "ring_frag",
                          blend: true, topo: .line)
        corePSO     = pso(vert: "core_vert",     frag: "core_frag",     blend: true)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let cmdBuf  = commandQueue.makeCommandBuffer(),
              let enc     = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)
        else { return }

        let t = Float(Date().timeIntervalSince(startTime))
        let reduceMotion: Float = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.0 : 0.0
        let size = view.drawableSize

        guard let core = core else {
            enc.endEncoding(); cmdBuf.present(drawable); cmdBuf.commit(); return
        }

        let aspect = Float(size.width / size.height)
        let fov: Float = 0.8
        let vp = perspectiveMatrix(fov: fov, aspect: aspect, near: 0.1, far: 100.0)
            * lookAtMatrix(eye: [0, 0, 2.5], center: [0,0,0], up: [0,1,0])

        let lod: Float = core.orbZoom > 2.2 ? 1.0 : 0.0

        let stateInt: Int32
        switch core.orbState {
        case .idle:       stateInt = 0
        case .listening:  stateInt = 1
        case .processing: stateInt = 2
        case .speaking:   stateInt = 3
        case .permission: stateInt = 4
        case .error:      stateInt = 5
        }

        let uniforms = OrbUniforms(
            modelMatrix:    matrix_identity_float4x4,
            viewProjection: vp,
            time:           t,
            audioLevel:     core.audioLevel,
            orbStateInt:    stateInt,
            zoom:           core.orbZoom,
            yaw:            core.orbYaw,
            pitch:          core.orbPitch,
            lodLevel:       lod,
            reduceMotion:   reduceMotion
        )

        uniformBuffer?.contents().storeBytes(of: uniforms, as: OrbUniforms.self)

        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.008, 0.016, 0.040, 1.0)

        if let pso = starPSO {
            enc.setRenderPipelineState(pso)
            enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if let pso = corePSO {
            enc.setRenderPipelineState(pso)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if let pso = filamentPSO {
            enc.setRenderPipelineState(pso)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0,
                               vertexCount: 1, instanceCount: filamentCount)
        }
        if let pso = ringPSO {
            enc.setRenderPipelineState(pso)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .lineStrip, vertexStart: 0,
                               vertexCount: ringSegments + 1, instanceCount: ringCount)
        }

        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

// ─── Math helpers ─────────────────────────────────────────────────────────────

private func perspectiveMatrix(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fov * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(
        [x, 0, 0,  0],
        [0, y, 0,  0],
        [0, 0, z, -1],
        [0, 0, z * near, 0]
    )
}

private func lookAtMatrix(eye: simd_float3, center: simd_float3, up: simd_float3) -> simd_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return simd_float4x4(
        [s.x,  u.x,  -f.x, 0],
        [s.y,  u.y,  -f.y, 0],
        [s.z,  u.z,  -f.z, 0],
        [-dot(s, eye), -dot(u, eye), dot(f, eye), 1]
    )
}
