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
        ZStack {
#if CANVAS_RENDERER
            OrbCanvasView()
                .environmentObject(karen)
#else
            OrbMTKView()
                .environmentObject(karen)
#endif
            MemoryOrbNodeOverlay(labels: karen.memoryNodeLabels,
                                 zoom: karen.orbZoom,
                                 offsetX: karen.orbOffsetX,
                                 offsetY: karen.orbOffsetY,
                                 state: karen.orbState)
        }
    }
}

private struct MemoryOrbNodeOverlay: View {
    let labels: [String]
    let zoom: Float
    let offsetX: Float
    let offsetY: Float
    let state: OrbState

    private var visibility: Double {
        let amount = min(max((Double(zoom) - 2.0) / 1.5, 0), 1)
        return amount * amount * (3 - 2 * amount)
    }

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2 + CGFloat(offsetX) * min(geometry.size.width, geometry.size.height) * 0.28,
                                 y: geometry.size.height / 2 - CGFloat(offsetY) * min(geometry.size.width, geometry.size.height) * 0.28)
            ZStack {
                Canvas { context, _ in
                    guard labels.count > 0 else { return }
                    var links = Path()
                    for index in labels.indices {
                        let point = nodePosition(index: index, count: labels.count, size: geometry.size, center: center)
                        links.move(to: center)
                        links.addLine(to: point)
                        if index > 0 {
                            let previous = nodePosition(index: index - 1, count: labels.count, size: geometry.size, center: center)
                            links.move(to: previous)
                            links.addLine(to: point)
                        }
                    }
                    context.stroke(links, with: .color(KarenTheme.accent(for: state).opacity(0.32 * visibility)), lineWidth: 0.8)
                }

                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    let point = nodePosition(index: index, count: labels.count, size: geometry.size, center: center)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(KarenTheme.accent(for: state))
                            .frame(width: 5, height: 5)
                        Text(label)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 126, alignment: .leading)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.012, green: 0.022, blue: 0.045).opacity(0.92), in: Capsule())
                    .overlay(Capsule().strokeBorder(KarenTheme.accent(for: state).opacity(0.52), lineWidth: 0.7))
                    .foregroundStyle(.white.opacity(0.96))
                    .shadow(color: KarenTheme.accent(for: state).opacity(0.2), radius: 7)
                    .help(label)
                    .position(point)
                    .opacity(visibility)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: visibility)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Saved memories appear as labeled orb nodes when zoomed in")
    }

    private func nodePosition(index: Int, count: Int, size: CGSize, center: CGPoint) -> CGPoint {
        let slotsPerRing = min(10, max(count, 1))
        let ring = index / slotsPerRing
        let slot = index % slotsPerRing
        let remaining = count - ring * slotsPerRing
        let slots = min(slotsPerRing, remaining)
        let angle = Double(slot) / Double(max(slots, 1)) * 2 * Double.pi - Double.pi / 2 + Double(ring) * 0.19
        let ringRadius = min(0.43, 0.23 + Double(ring) * 0.105)
        return CGPoint(x: center.x + cos(angle) * size.width * ringRadius,
                       y: center.y + sin(angle) * size.height * ringRadius)
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
