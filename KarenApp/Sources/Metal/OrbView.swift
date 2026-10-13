import SwiftUI
import MetalKit

// ─── OrbView — routes to Metal or Canvas renderer ────────────────────────────
//
// CANVAS_RENDERER is defined when building with `swift build` (CLI tools).
// Full Xcode builds use MTKView + OrbRenderer (Metal shaders).

struct OrbView: View {
    @EnvironmentObject var karen: KarenCore

    var body: some View {
        // Both OrbMTKView (Metal) and OrbCanvasView (Canvas) are included
        // in the Xcode build. When building with `swift build` only
        // OrbCanvasView is used.
#if CANVAS_RENDERER
        OrbCanvasView()
            .environmentObject(karen)
#else
        OrbMTKView()
            .environmentObject(karen)
#endif
    }
}

// ─── NSViewRepresentable wrapper for MTKView ─────────────────────────────────

struct OrbMTKView: NSViewRepresentable {
    @EnvironmentObject var karen: KarenCore

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.008, 0.016, 0.040, 1.0)
        view.layer?.isOpaque = false

        if let device = MTLCreateSystemDefaultDevice() {
            view.device = device
            if let renderer = OrbRenderer(device: device, core: karen) {
                view.delegate = renderer
                context.coordinator.renderer = renderer
            } else {
                print("[OrbMTKView] ⚠️ Renderer init failed — shaders may not be compiled")
            }
        } else {
            print("[OrbMTKView] ⚠️ No Metal device available")
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.core = karen
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var renderer: OrbRenderer?
    }
}

// ─── Orb state indicator overlay ─────────────────────────────────────────────

struct OrbStateIndicator: View {
    let state: OrbState

    var icon: String {
        switch state {
        case .idle:       return "sparkle"
        case .listening:  return "mic.fill"
        case .processing: return "circle.dotted"
        case .speaking:   return "waveform"
        case .permission: return "lock.fill"
        case .error:      return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch state {
        case .idle:       return "Idle"
        case .listening:  return "Listening…"
        case .processing: return "Thinking…"
        case .speaking:   return "Speaking"
        case .permission: return "Permission needed"
        case .error:      return "Error"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .imageScale(.small)
                .symbolEffect(.pulse, isActive: state == .listening || state == .processing)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(KarenTheme.accent(for: state))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(KarenTheme.accent(for: state).opacity(0.3), lineWidth: 1))
        .animation(.easeInOut(duration: 0.45), value: state)
        .accessibilityLabel("K.A.R.E.N. state: \(label)")
    }
}
