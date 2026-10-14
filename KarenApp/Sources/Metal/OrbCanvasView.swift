import SwiftUI
import Foundation

// ─── OrbCanvasView ────────────────────────────────────────────────────────────
//
// Procedural SwiftUI Canvas renderer implementing all 6 orb states.
// Active when built with `swift build` (no Xcode.app / metal compiler).
// Metal implementation (Orb.metal) delivers equivalent visuals via Xcode.
//
// Renders (per frame, 60 fps via TimelineView):
//   1. Star field — hashed sparse stars with twinkle
//   2. Core glow  — Gaussian radial gradient at center
//   3. Filament shells — 3 concentric point clouds on Fibonacci sphere
//   4. Orbiting rings — 3 tilted ellipses
//   5. State overlay — distinct icon+pattern for each state

struct OrbCanvasView: View {
    @EnvironmentObject var karen: KarenCore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60.0, paused: false)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let speed: Double = reduceMotion ? 0.15 : 1.0
                let offsetX = karen.orbOffsetX
                let offsetY = karen.orbOffsetY

                drawStars(ctx: ctx, size: size, t: t, state: karen.orbState)
                drawCoreGlow(ctx: ctx, size: size, t: t, speed: speed, state: karen.orbState,
                             zoom: karen.orbZoom,
                             offsetX: offsetX, offsetY: offsetY)
                drawCoreApproach(ctx: ctx, size: size, t: t, zoom: karen.orbZoom,
                                 state: karen.orbState, offsetX: offsetX, offsetY: offsetY)
                drawNeuralNetwork(ctx: ctx, size: size, t: t, speed: speed,
                                  zoom: karen.orbZoom, yaw: karen.orbYaw, pitch: karen.orbPitch,
                                  state: karen.orbState,
                                  offsetX: offsetX, offsetY: offsetY)
                drawFilamentShells(ctx: ctx, size: size, t: t, speed: speed,
                                   state: karen.orbState, audioLevel: karen.audioLevel,
                                   zoom: karen.orbZoom, yaw: karen.orbYaw, pitch: karen.orbPitch,
                                   offsetX: offsetX, offsetY: offsetY,
                                   lod: karen.orbZoom > 2.2)
                drawRings(ctx: ctx, size: size, t: t, speed: speed,
                          state: karen.orbState, audioLevel: karen.audioLevel,
                          zoom: karen.orbZoom, yaw: karen.orbYaw, pitch: karen.orbPitch,
                          offsetX: offsetX, offsetY: offsetY)
                drawStateOverlay(ctx: ctx, size: size, t: t, state: karen.orbState)
            }
        }
    }
}

// ─── Stars ────────────────────────────────────────────────────────────────────

private func drawStars(ctx: GraphicsContext, size: CGSize, t: Double, state: OrbState) {
    // Deep-space field with a broad, faint Milky Way band and a distant light source.
    ctx.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .linearGradient(
            Gradient(colors: [
                Color(red: 0.001, green: 0.002, blue: 0.006),
                Color(red: 0.003, green: 0.005, blue: 0.014),
                Color(red: 0.001, green: 0.002, blue: 0.007)
            ]),
            startPoint: CGPoint(x: size.width * (0.48 + 0.025 * sin(t * 0.018)), y: 0),
            endPoint: CGPoint(x: size.width * (0.52 + 0.025 * cos(t * 0.016)), y: size.height)
        )
    )

    let accent = KarenTheme.accentRGB(for: state)
    let galaxyStart = CGPoint(x: size.width * 0.08, y: size.height * 0.93)
    let galaxyEnd = CGPoint(x: size.width * 0.93, y: size.height * 0.12)
    var galaxyBand = Path()
    galaxyBand.move(to: galaxyStart)
    galaxyBand.addLine(to: galaxyEnd)
    ctx.stroke(galaxyBand,
               with: .color(Color(red: 0.48, green: 0.59, blue: 0.78, opacity: 0.025)),
               style: StrokeStyle(lineWidth: size.height * 0.34, lineCap: .round))
    ctx.stroke(galaxyBand,
               with: .color(Color(red: 0.62, green: 0.70, blue: 0.86, opacity: 0.025)),
               style: StrokeStyle(lineWidth: size.height * 0.12, lineCap: .round))

    let lightSource = CGPoint(x: size.width * 0.80, y: size.height * 0.19)
    ctx.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .radialGradient(
            Gradient(stops: [
                .init(color: Color.white.opacity(0.36), location: 0),
                .init(color: Color(red: 0.72, green: 0.83, blue: 1.0, opacity: 0.20), location: 0.035),
                .init(color: Color(red: accent.r, green: accent.g, blue: accent.b, opacity: 0.075), location: 0.16),
                .init(color: Color.clear, location: 1)
            ]),
            center: lightSource,
            startRadius: 0,
            endRadius: min(size.width, size.height) * 0.72
        )
    )

    // Point-source flare: a crisp star core, soft bloom, and fine light rays.
    let pulse = 1.0
    let halo = CGFloat(11 * pulse)
    ctx.fill(Path(ellipseIn: CGRect(x: lightSource.x - halo, y: lightSource.y - halo,
                                    width: halo * 2, height: halo * 2)),
             with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.08), .clear]),
                center: lightSource, startRadius: 0, endRadius: halo
             ))
    var flare = Path()
    flare.move(to: CGPoint(x: lightSource.x - 7, y: lightSource.y))
    flare.addLine(to: CGPoint(x: lightSource.x + 7, y: lightSource.y))
    flare.move(to: CGPoint(x: lightSource.x, y: lightSource.y - 7))
    flare.addLine(to: CGPoint(x: lightSource.x, y: lightSource.y + 7))
    ctx.stroke(flare, with: .color(Color.white.opacity(0.48)), lineWidth: 0.65)

    // Dense fine stars; the diagonal galactic band has a richer star field.
    let gridX = 84, gridY = 56
    for ix in 0..<gridX {
        for iy in 0..<gridY {
            let h = fhash(Float(ix) * 443.9 + Float(iy) * 441.4 + 17.0)
            let xUnit = Double(ix) / Double(gridX)
            let yUnit = Double(iy) / Double(gridY)
            let bandDistance = abs(yUnit - (0.93 - xUnit * 0.81))
            let inGalaxy = bandDistance < 0.20
            guard h > (inGalaxy ? 0.91 : 0.975) else { continue }
            let x = (Double(ix) + Double(fhash(Float(ix) * 7.3 + Float(iy)))) / Double(gridX) * size.width
            let y = (Double(iy) + Double(fhash(Float(iy) * 13.1 + Float(ix)))) / Double(gridY) * size.height
            let r = CGFloat(inGalaxy ? 0.78 : 0.58)
            let alpha = CGFloat(inGalaxy ? 0.22 : 0.14)
            ctx.fill(Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)),
                     with: .color(Color(red: inGalaxy ? 0.82 : 0.72,
                                         green: inGalaxy ? 0.88 : 0.80,
                                         blue: inGalaxy ? 1.0 : 0.92, opacity: alpha)))
        }
    }
    let sourceDot = CGRect(x: lightSource.x - 1.7 * pulse, y: lightSource.y - 1.7 * pulse,
                           width: 3.4 * pulse, height: 3.4 * pulse)
    ctx.fill(Path(ellipseIn: sourceDot),
             with: .color(Color.white.opacity(0.98)))
}

// ─── Core glow ────────────────────────────────────────────────────────────────

private func drawCoreGlow(ctx: GraphicsContext, size: CGSize, t: Double, speed: Double,
                          state: OrbState, zoom: Float, offsetX: Float, offsetY: Float) {
    let centerOffset = min(size.width, size.height) * 0.28
    let cx = size.width / 2 + CGFloat(offsetX) * centerOffset
    let cy = size.height / 2 - CGFloat(offsetY) * centerOffset
    var intensity: CGFloat = 0.55
    if state == .processing {
        intensity *= CGFloat(0.97 + 0.03 * sin(t * 0.55 * speed))
    } else if state == .error {
        intensity *= CGFloat(0.78 + 0.04 * sin(t * 0.45))
    }
    let approach = smoothZoomProgress(zoom, startsAt: 1.15, endsAt: 7.5)
    let accent = KarenTheme.accentRGB(for: state)
    let radius = min(size.width, size.height) * (0.12 + approach * 0.09)
    intensity *= CGFloat(1.0 + approach * 0.55)
    ctx.fill(
        Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: radius*2, height: radius*2)),
        with: .radialGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.74 + accent.r * 0.26,
                                   green: 0.74 + accent.g * 0.26,
                                   blue: 0.74 + accent.b * 0.26, opacity: intensity), location: 0.0),
                .init(color: Color(red: accent.r, green: accent.g, blue: accent.b,
                                   opacity: intensity * 0.38), location: 0.45),
                .init(color: Color.clear, location: 1.0),
            ]),
            center: CGPoint(x: cx, y: cy),
            startRadius: 0,
            endRadius: radius
        )
    )
}

// A restrained animated field of inner rings becomes visible as the camera
// travels through the outer shells toward the bright center of the orb.
private func drawCoreApproach(ctx: GraphicsContext, size: CGSize, t: Double,
                              zoom: Float, state: OrbState, offsetX: Float, offsetY: Float) {
    let approach = smoothZoomProgress(zoom, startsAt: 1.55, endsAt: 7.5)
    guard approach > 0.001 else { return }
    let minimumDimension = min(size.width, size.height)
    let centerOffset = minimumDimension * 0.28
    let cx = size.width / 2 + CGFloat(offsetX) * centerOffset
    let cy = size.height / 2 - CGFloat(offsetY) * centerOffset

    let accent = KarenTheme.accentRGB(for: state)
    for index in 0..<8 {
        let phase = (t * 0.085 + Double(index) / 8.0).truncatingRemainder(dividingBy: 1.0)
        let radius = minimumDimension * (0.012 + phase * 0.055) * zoomedRadius(zoom)
        let rotation = t * 0.07 + Double(index) * 0.38
        var path = Path()
        for step in 0...72 {
            let angle = Double(step) / 72.0 * .pi * 2.0
            let x = radius * cos(angle)
            let y = radius * 0.32 * sin(angle)
            let px = cx + x * cos(rotation) - y * sin(rotation)
            let py = cy + x * sin(rotation) + y * cos(rotation)
            if step == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        let opacity = CGFloat(approach * (0.035 + (1.0 - phase) * 0.055))
        ctx.stroke(path,
                   with: .color(Color(red: accent.r, green: accent.g, blue: accent.b, opacity: opacity)),
                   lineWidth: CGFloat(0.55 + approach * 0.55))
    }
}

private func smoothZoomProgress(_ zoom: Float, startsAt: Double, endsAt: Double) -> Double {
    let linear = min(max((Double(zoom) - startsAt) / (endsAt - startsAt), 0), 1)
    return linear * linear * (3.0 - 2.0 * linear)
}

private func zoomedRadius(_ zoom: Float) -> Double {
    pow(max(Double(zoom), 0.05), 1.16)
}

// ─── Filament shells ──────────────────────────────────────────────────────────

private func drawFilamentShells(ctx: GraphicsContext, size: CGSize, t: Double, speed: Double,
                                 state: OrbState, audioLevel: Float,
                                 zoom: Float, yaw: Float, pitch: Float,
                                 offsetX: Float, offsetY: Float, lod: Bool) {
    let centerOffset = min(size.width, size.height) * 0.28
    let cx = size.width / 2 + CGFloat(offsetX) * centerOffset
    let cy = size.height / 2 - CGFloat(offsetY) * centerOffset
    let baseRadius = min(size.width, size.height) * 0.40 * zoomedRadius(zoom)

    let N = lod ? min(3_200, 1_900 + Int(max(zoom - 2.2, 0) * 500)) : 800
    let phi_g = Double.pi * (1.0 + sqrt(5.0))

    for i in 0..<N {
        let fi    = Double(i)
        let phi   = acos(1.0 - 2.0*(fi+0.5)/Double(N))
        let theta = phi_g * fi

        let shell  = i % 3
        let shellR = 0.70 + Double(shell) * 0.22

        // State-based radius modulation
        var r = shellR
        let breathe = sin(t * 0.35 * speed) * 0.008
        // Keep the shell's fine structure anchored to each node. Moving the
        // noise field per frame made the lights shimmer like random flicker.
        let noiseOff = Double(fnoise(Float(sin(theta)*cos(phi)), Float(sin(phi)), Float(cos(theta)))) * 0.06
        r = r + breathe + noiseOff

        switch state {
        case .listening:
            let equatorBias = 1.0 - abs(cos(phi)) * 0.38
            r *= equatorBias
            r += Double(audioLevel) * 0.012
        case .processing:
            r *= 0.86 + sin(t * 0.48 * speed) * 0.015
        case .speaking:
            let wave = sin(phi * 5.0 + t * 2.0 * speed) * 0.018 * (1.0 + Double(audioLevel))
            r += wave
        case .permission:
            r = shellR + sin(t * 0.3) * 0.006
        case .error:
            r = shellR * 0.96
        default:
            break
        }

        if lod {
            r *= 0.68
            r += Double(fnoise(Float(phi), Float(theta), 0.5)) * 0.14
        }

        // Spherical → Cartesian
        var px = r * sin(phi) * cos(theta)
        var py = r * cos(phi)
        var pz = r * sin(phi) * sin(theta)

        // Apply yaw/pitch
        let y = Double(yaw), p = Double(pitch)
        let px2 =  px * cos(y) + pz * sin(y)
        let pz2 = -px * sin(y) + pz * cos(y)
        px = px2; pz = pz2
        let py2 =  py * cos(p) - pz * sin(p)
        let pz3 =  py * sin(p) + pz * cos(p)
        py = py2; pz = pz3

        // Perspective
        let depth = 2.5 + pz * 0.3
        let sx = cx + px * baseRadius / depth
        let sy = cy - py * baseRadius / depth

        guard sx > 0, sx < size.width, sy > 0, sy < size.height else { continue }

        // Color
        let distNorm = min(r / 0.95, 1.0)
        let (cr, cg, cb) = orbColor(t: distNorm, state: state)
        let alpha = CGFloat(mix(0.85, 0.18, distNorm))
        let ptSize = CGFloat(mix(2.8, 1.0, distNorm))
            * CGFloat(min(zoom, 1.8)) * (lod ? 0.65 : 1.0)

        ctx.fill(
            Path(ellipseIn: CGRect(x: sx - ptSize/2, y: sy - ptSize/2,
                                   width: ptSize, height: ptSize)),
            with: .color(Color(red: cr, green: cg, blue: cb, opacity: alpha))
        )
    }
}

// ─── Zoomed neural network ────────────────────────────────────────────────────

private func drawNeuralNetwork(ctx: GraphicsContext, size: CGSize, t: Double, speed: Double,
                               zoom: Float, yaw: Float, pitch: Float,
                               state: OrbState,
                               offsetX: Float, offsetY: Float) {
    guard zoom > 1.15 else { return }

    let zoomAmount = min(max(log2(max(Double(zoom), 1.0)) / 3.0, 0), 1)
    let count = min(2_600, 520 + Int(zoomAmount * 2_080))
    let minimumDimension = min(size.width, size.height)
    let centerOffset = minimumDimension * 0.28
    let cx = size.width / 2 + CGFloat(offsetX) * centerOffset
    let cy = size.height / 2 - CGFloat(offsetY) * centerOffset
    let radius = minimumDimension * 0.40 * zoomedRadius(zoom)
    let goldenAngle = Double.pi * (3.0 - sqrt(5.0))

    struct Node {
        let point: CGPoint
        let z: Double
    }
    var nodes: [Node] = []
    nodes.reserveCapacity(count)

    for i in 0..<count {
        let fi = Double(i)
        let y = 1.0 - 2.0 * (fi + 0.5) / Double(count)
        let ringRadius = sqrt(max(0, 1.0 - y * y))
        let theta = goldenAngle * fi
        let nodeRadius = 0.78 + Double(i % 4) * 0.055
        var px = cos(theta) * ringRadius * nodeRadius
        var py = y * nodeRadius
        var pz = sin(theta) * ringRadius * nodeRadius

        let yawAngle = Double(yaw)
        let pitchAngle = Double(pitch)
        let yawX = px * cos(yawAngle) + pz * sin(yawAngle)
        let yawZ = -px * sin(yawAngle) + pz * cos(yawAngle)
        px = yawX
        pz = yawZ
        let pitchY = py * cos(pitchAngle) - pz * sin(pitchAngle)
        let pitchZ = py * sin(pitchAngle) + pz * cos(pitchAngle)
        py = pitchY
        pz = pitchZ

        let depth = 2.5 + pz * 0.3
        nodes.append(Node(
            point: CGPoint(x: cx + px * radius / depth,
                           y: cy - py * radius / depth),
            z: pz
        ))
    }

    var quietLinks = Path()
    var highlightedLinks = Path()
    var nodeHalos = Path()
    var nodeCores = Path()
    let linkOffsets = [1, 2, 3, 8]
    let linkLimit = minimumDimension * min(0.22, 0.075 + Double(zoomAmount) * 0.12)

    for i in 0..<count {
        let node = nodes[i]
        guard node.point.x > -10, node.point.x < size.width + 10,
              node.point.y > -10, node.point.y < size.height + 10 else { continue }

        let nodeRadius = CGFloat(0.72 + zoomAmount * 0.38)
        let nodeRect = CGRect(x: node.point.x - nodeRadius,
                              y: node.point.y - nodeRadius,
                              width: nodeRadius * 2, height: nodeRadius * 2)
        nodeHalos.addEllipse(in: nodeRect.insetBy(dx: -1.35, dy: -1.35))
        nodeCores.addEllipse(in: nodeRect)

        for linkOffset in linkOffsets {
            let neighborIndex = i + linkOffset
            guard neighborIndex < count else { continue }
            let neighbor = nodes[neighborIndex]
            let dx = neighbor.point.x - node.point.x
            let dy = neighbor.point.y - node.point.y
            guard hypot(dx, dy) < linkLimit else { continue }

            // Keep the topology and brightness steady; a fixed sparse subset
            // gets a brighter trace so the network reads as illuminated.
            let isHighlighted = (i + linkOffset * 7) % 5 == 0
            var path = isHighlighted ? highlightedLinks : quietLinks
            path.move(to: node.point)
            path.addLine(to: neighbor.point)
            if isHighlighted { highlightedLinks = path } else { quietLinks = path }
        }
    }

    let accent = KarenTheme.accentRGB(for: state)
    let fieldBreath = 0.94 + 0.06 * sin(t * 0.32 * speed)
    let fieldRadius = minimumDimension * CGFloat(0.58 + zoomAmount * 0.08)
    ctx.fill(Path(CGRect(origin: .zero, size: size)),
             with: .radialGradient(
                Gradient(colors: [
                    Color(red: min(1, accent.r * 0.45 + 0.24),
                          green: min(1, accent.g * 0.45 + 0.24),
                          blue: min(1, accent.b * 0.45 + 0.24),
                          opacity: 0.12 * fieldBreath),
                    Color(red: accent.r, green: accent.g, blue: accent.b, opacity: 0.045),
                    .clear
                ]),
                center: CGPoint(x: cx, y: cy),
                startRadius: 0,
                endRadius: fieldRadius
             ))
    ctx.stroke(quietLinks,
               with: .color(Color(red: accent.r * 0.55, green: accent.g * 0.62,
                                  blue: accent.b * 0.92, opacity: 0.28)),
               lineWidth: 0.62)
    ctx.stroke(highlightedLinks,
               with: .color(Color(red: min(1, accent.r * 0.55 + 0.35),
                                  green: min(1, accent.g * 0.55 + 0.35),
                                  blue: min(1, accent.b * 0.55 + 0.35), opacity: 0.62)),
               lineWidth: 0.9)
    ctx.fill(nodeHalos,
             with: .color(Color(red: accent.r, green: accent.g,
                                blue: accent.b, opacity: 0.16 * fieldBreath)))
    ctx.fill(nodeCores,
             with: .color(Color(red: min(1, 0.72 + accent.r * 0.28),
                                green: min(1, 0.72 + accent.g * 0.28),
                                blue: min(1, 0.72 + accent.b * 0.28), opacity: 0.95)))
}

// ─── Orbiting rings ───────────────────────────────────────────────────────────

private func drawRings(ctx: GraphicsContext, size: CGSize, t: Double, speed: Double,
                        state: OrbState, audioLevel: Float,
                        zoom: Float, yaw: Float, pitch: Float,
                        offsetX: Float, offsetY: Float) {
    let centerOffset = min(size.width, size.height) * 0.28
    let cx = size.width / 2 + CGFloat(offsetX) * centerOffset
    let cy = size.height / 2 - CGFloat(offsetY) * centerOffset
    let baseR = min(size.width, size.height) * 0.40 * zoomedRadius(zoom)

    struct Ring { let tilt: Double; let radius: Double; let rotSpeed: Double }
    let rings = [
        Ring(tilt:  0.42, radius: 0.95, rotSpeed:  0.25),
        Ring(tilt: -0.65, radius: 0.82, rotSpeed: -0.18),
        Ring(tilt:  0.25, radius: 1.08, rotSpeed:  0.31),
    ]

    let SEGS = 120
    for ring in rings {
        var R = ring.radius
        var rotAngle = t * ring.rotSpeed * speed

        switch state {
        case .listening:
            R *= 0.82 + Double(audioLevel) * 0.10
        case .processing:
            rotAngle = t * ring.rotSpeed * speed * 3.2
        case .permission:
            rotAngle = 0
        default:
            break
        }

        var points: [CGPoint] = []

        for seg in 0...SEGS {
            let angle = Double(seg) / Double(SEGS) * 2.0 * .pi
            var px = R * cos(angle)
            var py = 0.0
            var pz = R * sin(angle)

            // Tilt
            let t2 = ring.tilt
            let py2 =  py * cos(t2) - pz * sin(t2)
            let pz2 =  py * sin(t2) + pz * cos(t2)
            py = py2; pz = pz2

            // Spin
            let px3 = px * cos(rotAngle) + pz * sin(rotAngle)
            let pz3 = -px * sin(rotAngle) + pz * cos(rotAngle)
            px = px3; pz = pz3

            // User yaw/pitch
            let y = Double(yaw), p = Double(pitch)
            let px4 =  px * cos(y) + pz * sin(y)
            let pz4 = -px * sin(y) + pz * cos(y)
            px = px4; pz = pz4
            let py4 =  py * cos(p) - pz4 * sin(p)
            pz = py * sin(p) + pz4 * cos(p)
            py = py4

            let depth = 2.5 + pz * 0.3
            let sx = cx + px * baseR / depth
            let sy = cy - py * baseR / depth
            points.append(CGPoint(x: sx, y: sy))
        }

        var path = Path()
        if let first = points.first {
            path.move(to: first)
            for pt in points.dropFirst() { path.addLine(to: pt) }
        }
        let alpha: CGFloat = state == .permission ? 0.95 : 0.45
        let accent = KarenTheme.accentRGB(for: state)
        let color = Color(red: accent.r, green: accent.g, blue: accent.b, opacity: alpha)

        ctx.stroke(path, with: .color(color), lineWidth: state == .permission ? 1.5 : 1.0)
    }
}

// ─── State overlay ────────────────────────────────────────────────────────────

private func drawStateOverlay(ctx: GraphicsContext, size: CGSize, t: Double, state: OrbState) {
    // Only draw extra visual patterns for states that need them
    let cx = size.width / 2
    let cy = size.height / 2

    switch state {
    case .permission:
        // Lock icon visual (rings locked — drawn as concentric fixed circles)
        for r in [0.18, 0.22] {
            let radius = min(size.width, size.height) * r
            var p = Path()
            p.addEllipse(in: CGRect(x: cx-radius, y: cy-radius, width: radius*2, height: radius*2))
        let accent = KarenTheme.accentRGB(for: state)
        ctx.stroke(p, with: .color(Color(red: accent.r, green: accent.g, blue: accent.b, opacity: 0.3)),
                       lineWidth: 1.5)
        }
    case .error:
        // Broken ring gap indicator — draw arc with gap
        let radius = min(size.width, size.height) * 0.32
        var p = Path()
        p.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                 startAngle: .degrees(30), endAngle: .degrees(320), clockwise: false)
        let accent = KarenTheme.accentRGB(for: state)
        ctx.stroke(p, with: .color(Color(red: accent.r, green: accent.g, blue: accent.b, opacity: 0.6)),
                   lineWidth: 2.0)
    default:
        break
    }
}

// ─── Math helpers ─────────────────────────────────────────────────────────────

private func fhash(_ n: Float) -> Float {
    var x = n
    x = fract(x * 443.897)
    x += dot(x, x + 19.19)
    return fract(x * x)
}

private func fhash(_ x: Float, _ y: Float) -> Float {
    fhash(x * 443.897 + y * 441.423)
}

private func fract(_ x: Float) -> Float  { x - floor(x) }
private func fract(_ x: Double) -> Double { x - floor(x) }
private func dot(_ a: Float, _ b: Float) -> Float { a * b }

private func fnoise(_ x: Float, _ y: Float, _ z: Float) -> Float {
    let ix = floor(x), iy = floor(y), iz = floor(z)
    let fx = x - ix, fy = y - iy, fz = z - iz
    let ux = fx*fx*(3-2*fx), uy = fy*fy*(3-2*fy), uz = fz*fz*(3-2*fz)
    let h000 = fhash(ix,     iy)
    let h100 = fhash(ix+1.0, iy)
    let h010 = fhash(ix,     iy+1.0)
    let h110 = fhash(ix+1.0, iy+1.0)
    return h000*(1-ux)*(1-uy) + h100*ux*(1-uy) + h010*(1-ux)*uy + h110*ux*uy + uz*0.1
}

private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}
private func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
}

private func orbColor(t: Double, state: OrbState) -> (CGFloat, CGFloat, CGFloat) {
    let accent = KarenTheme.accentRGB(for: state)
    let core = (r: min(1, accent.r * 0.24 + 0.76),
                g: min(1, accent.g * 0.24 + 0.76),
                b: min(1, accent.b * 0.24 + 0.76))
    if t < 0.4 {
        let s = t / 0.4
        return (mix(core.r, accent.r, s), mix(core.g, accent.g, s), mix(core.b, accent.b, s))
    } else {
        let s = (t - 0.4) / 0.6
        return (mix(accent.r, accent.r * 0.26, s),
                mix(accent.g, accent.g * 0.30, s),
                mix(accent.b, accent.b * 0.44, s))
    }
}
