import SwiftUI

// ─── Main content view ────────────────────────────────────────────────────────

struct ContentView: View {
    @EnvironmentObject var karen: KarenCore
    @State private var showGestureGuide = false

    var body: some View {
        ZStack {
            // Deep space and its distant light source follow the active theme.
            LinearGradient(colors: KarenTheme.backdrop(for: karen.orbState),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.7), value: karen.orbState)
            RadialGradient(colors: [KarenTheme.accent(for: karen.orbState).opacity(0.16), .clear],
                           center: UnitPoint(x: 0.79, y: 0.20), startRadius: 0, endRadius: 680)
                .ignoresSafeArea()
                .blendMode(.screen)
                .animation(.easeInOut(duration: 0.7), value: karen.orbState)

            // Orb renderer (Metal when Xcode build, Canvas when swift build)
            OrbView()
                .ignoresSafeArea()
                .accessibilityLabel("K.A.R.E.N. neural orb visualization")
                .accessibilityHint("Use controls below to interact")
                // Mouse/trackpad interaction
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            karen.applyRotation(
                                yaw:   Float(v.translation.width)  * 0.005,
                                pitch: Float(v.translation.height) * 0.005
                            )
                        }
                )
                .onScrollWheel { delta in
                    karen.applyZoom(Float(1.0 + delta.y * 0.02))
                }
                .animation(.easeInOut(duration: 0.7), value: karen.orbState)

            // Bottom HUD
            VStack {
                Spacer()
                HUDBar()
                    .padding(.bottom, 20)
            }

            // Reply text overlay
            if !karen.replyText.isEmpty {
                VStack {
                    Spacer()
                        .frame(height: 60)
                    ReplyBubble(text: karen.replyText)
                    Spacer()
                }
            }

            // State badge (top center)
            VStack {
                HStack {
                    Spacer()
                    OrbStateIndicator(state: karen.orbState)
                        .padding(.top, 16)
                        .padding(.trailing, 16)
                }
                Spacer()
            }

            // Gesture guide overlay
            if showGestureGuide {
                GestureGuideOverlay(dismiss: { showGestureGuide = false })
            }
        }
        .sheet(isPresented: $karen.showSettings) {
            SettingsView()
                .environmentObject(karen)
        }
        .sheet(isPresented: $karen.showPermissions) {
            PermissionsCenterView()
                .environmentObject(karen)
        }
        .sheet(isPresented: $karen.showMemory, onDismiss: {
            karen.closeMemoryMap()
        }) {
            MemoryView()
                .environmentObject(karen)
        }
        .confirmationDialog(
            karen.pendingConfirm?.description ?? "",
            isPresented: Binding(
                get: { karen.pendingConfirm != nil },
                set: { if !$0 { karen.pendingConfirm?.onCancel(); karen.pendingConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let c = karen.pendingConfirm {
                Button("Confirm") { c.onConfirm(); karen.pendingConfirm = nil }
                Button("Cancel", role: .cancel) { c.onCancel(); karen.pendingConfirm = nil }
            }
        }
        .onAppear {
            karen.requestMic()
            karen.requestCamera()
        }
        .frame(minWidth: 680, minHeight: 560)
    }
}

// ─── HUD bar ─────────────────────────────────────────────────────────────────

struct HUDBar: View {
    @EnvironmentObject var karen: KarenCore

    var body: some View {
        HStack(spacing: 16) {
            // Mic / listening toggle
            HUDButton(
                icon:    karen.isListening ? "mic.fill" : "mic.slash.fill",
                label:   karen.isListening ? "Stop" : "Listen",
                active:  karen.isListening,
                tint:    karen.isListening ? KarenTheme.accent(for: karen.orbState) : .white
            ) {
                karen.toggleListening()
            }
            .keyboardShortcut("l", modifiers: .command)
            .accessibilityLabel(karen.isListening ? "Stop listening" : "Start listening")

            // Mute toggle
            HUDButton(icon: karen.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                      label: karen.isMuted ? "Unmute" : "Mute",
                      active: karen.isMuted, tint: .white) {
                karen.toggleMute()
            }
            .accessibilityLabel(karen.isMuted ? "Unmute K.A.R.E.N." : "Mute K.A.R.E.N.")

            // Stop speaking
            HUDButton(icon: "stop.fill", label: "Stop", active: false, tint: .white) {
                karen.stopSpeaking()
            }
            .accessibilityLabel("Stop speaking")

            Divider().frame(height: 28).opacity(0.3)

            // Wake word toggle
            HUDButton(
                icon:   karen.wakeWordEnabled ? "waveform.badge.mic" : "waveform.slash",
                label:  karen.wakeWordEnabled ? "Wake On" : "Wake Off",
                active: karen.wakeWordEnabled,
                tint: karen.wakeWordEnabled ? KarenTheme.accent(for: karen.orbState) : .white
            ) { karen.toggleWakeWord() }
            .accessibilityLabel(karen.wakeWordEnabled ? "Wake word on" : "Wake word off")

            // Gesture mode
            HUDButton(
                icon:   karen.gestureMode ? "hand.raised.fill" : "hand.raised",
                label:  "Hands",
                active: karen.gestureMode,
                tint:   karen.gestureMode ? KarenTheme.accent(for: karen.orbState) : .white
            ) {
                if karen.gestureMode { karen.disableGestureMode() }
                else { karen.enableGestureMode() }
            }
            .accessibilityLabel(karen.gestureMode ? "Gesture mode on" : "Enable gesture mode")

            if karen.cameraActive {
                Label("Camera", systemImage: "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(KarenTheme.accent(for: karen.orbState))
                    .accessibilityLabel("Camera is active")
            }

            Spacer()

            // Reset orb
            HUDButton(icon: "arrow.uturn.backward.circle", label: "Reset",
                      active: false, tint: .white) {
                karen.resetOrb()
            }
            .accessibilityLabel("Reset orb view")

            // Memory
            HUDButton(icon: "brain", label: "Memory", active: false, tint: .white) {
                karen.openMemoryMap()
            }

            // Settings
            HUDButton(icon: "gear", label: "Settings", active: false, tint: .white) {
                karen.showSettings = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(KarenTheme.accent(for: karen.orbState).opacity(0.22), lineWidth: 1)
        }
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.45), value: karen.orbState)
    }
}

struct HUDButton: View {
    @EnvironmentObject var karen: KarenCore
    let icon: String
    let label: String
    let active: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .imageScale(.medium)
                    .foregroundStyle(active ? tint : KarenTheme.accent(for: karen.orbState).opacity(0.72))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(white: 0.65))
            }
        }
        .buttonStyle(.plain)
        .frame(width: 50)
    }
}

// ─── Reply bubble ─────────────────────────────────────────────────────────────

struct ReplyBubble: View {
    @EnvironmentObject var karen: KarenCore
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .regular, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(KarenTheme.panel(for: karen.orbState).opacity(0.96))
                    .strokeBorder(KarenTheme.accent(for: karen.orbState).opacity(0.42), lineWidth: 1)
            )
            .padding(.horizontal, 60)
            .animation(.easeInOut(duration: 0.45), value: karen.orbState)
            .accessibilityLabel("K.A.R.E.N. replied: \(text)")
    }
}

// ─── Gesture guide overlay ────────────────────────────────────────────────────

struct GestureGuideOverlay: View {
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Hand Gesture Controls")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Group {
                    GuideRow(icon: "hand.pinch.fill", text: "One hand: spread thumb and index to zoom")
                    GuideRow(icon: "hand.pinch", text: "Two hands: spread index fingers to zoom")
                    GuideRow(icon: "hand.point.up.left.fill", text: "Hold a pinch and drag to move")
                    GuideRow(icon: "hand.draw.fill", text: "Move an open palm to rotate")
                }
                Button("Got it") { dismiss() }
                    .keyboardShortcut(.escape)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
            }
            .padding(32)
            .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
        }
    }
}

struct GuideRow: View {
    let icon: String; let text: String
    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 28)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

// ─── Scroll wheel modifier ────────────────────────────────────────────────────

extension View {
    func onScrollWheel(_ handler: @escaping (CGPoint) -> Void) -> some View {
        self.background(ScrollWheelReader(handler: handler))
    }
}

struct ScrollWheelReader: NSViewRepresentable {
    let handler: (CGPoint) -> Void
    func makeNSView(context: Context) -> ScrollNSView {
        ScrollNSView(handler: handler)
    }
    func updateNSView(_ nsView: ScrollNSView, context: Context) {}
}

final class ScrollNSView: NSView {
    let handler: (CGPoint) -> Void
    init(handler: @escaping (CGPoint) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func scrollWheel(with event: NSEvent) {
        handler(CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
    }
}
