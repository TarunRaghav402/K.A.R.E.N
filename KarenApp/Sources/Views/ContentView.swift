import SwiftUI

// ─── Main content view ────────────────────────────────────────────────────────

struct ContentView: View {
    @EnvironmentObject var karen: KarenCore
    @Environment(\.openWindow) private var openWindow
    @State private var showGestureGuide = false
    @State private var typedInput = ""

    var body: some View {
        GeometryReader { geometry in
            let topTargetY: CGFloat = max(80, geometry.size.height * 0.16)
            let centerOffsetY: CGFloat = topTargetY - (geometry.size.height / 2)
            let currentOffsetY: CGFloat = karen.orbTopProgress * centerOffsetY
            let currentScale: CGFloat = 1.0 - (karen.orbTopProgress * 0.56) // 1.0 -> 0.44

            ZStack {
                // 1. Deep space and its distant light source — ALWAYS STATIC (never moves)
                LinearGradient(colors: KarenTheme.backdrop(for: karen.orbState),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.7), value: karen.orbState)
                RadialGradient(colors: [KarenTheme.accent(for: karen.orbState).opacity(0.16), .clear],
                               center: UnitPoint(x: 0.79, y: 0.20), startRadius: 0, endRadius: 680)
                    .ignoresSafeArea()
                    .blendMode(.screen)
                    .animation(.easeInOut(duration: 0.7), value: karen.orbState)

                // 2. Fixed background starfield & galaxy band — ALWAYS STATIC (never moves)
                StaticStarfieldCanvasView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                // 3. Neural Orb visualization — ONLY the orb glides up and scales down!
                OrbView()
                    .ignoresSafeArea()
                    .scaleEffect(currentScale, anchor: .center)
                    .offset(y: currentOffsetY)
                    .accessibilityLabel("K.A.R.E.N. neural orb visualization")
                    .accessibilityHint("Use controls below to interact")
                    // Mouse/trackpad interaction (only when not in voice interaction)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                guard !karen.isVoiceInteractionActive else { return }
                                karen.applyRotation(
                                    yaw:   Float(v.translation.width)  * 0.005,
                                    pitch: Float(v.translation.height) * 0.005
                                )
                            }
                    )
                    .onScrollWheel { delta in
                        guard !karen.isVoiceInteractionActive else { return }
                        karen.applyZoom(Float(1.0 + delta.y * 0.02))
                    }
                    .animation(.spring(response: 0.60, dampingFraction: 0.82), value: karen.orbTopProgress)
                    .animation(.easeInOut(duration: 0.7), value: karen.orbState)

                // 4. Coordinated Response Hierarchy: Connector + Dynamic Response Panel (Smooth Pop-up)
                VStack(spacing: 0) {
                    Spacer().frame(height: max(32, topTargetY + 54))

                    if karen.showConnector {
                        GlowingOrbConnector()
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.50, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.80, anchor: .top))
                            ))
                    }

                    if karen.showResponsePanel {
                        DynamicResponsePanel()
                            .transition(.asymmetric(
                                insertion: .opacity
                                    .combined(with: .scale(scale: 0.88, anchor: .top))
                                    .combined(with: .offset(y: -14)),
                                removal: .opacity
                                    .combined(with: .scale(scale: 0.90, anchor: .top))
                                    .combined(with: .offset(y: -8))
                            ))
                    }

                    Spacer().frame(minHeight: 90)
                }
                .animation(.spring(response: 0.54, dampingFraction: 0.80), value: karen.showResponsePanel)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: karen.showConnector)

                // Thinking feedback while processing in center
                if karen.orbState == .processing && !karen.showResponsePanel {
                    VStack {
                        Spacer()
                        ThinkingPulseBadge()
                            .padding(.bottom, 118)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .animation(.easeInOut(duration: 0.35), value: karen.orbState)
                }

                // Live Listening Overlay while listening in center
                if karen.orbState == .listening && !karen.showResponsePanel {
                    VStack {
                        Spacer()
                        LiveListeningIndicator()
                            .padding(.bottom, 115)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.spring(response: 0.45, dampingFraction: 0.78), value: karen.orbState)
                }

                // Bottom HUD
                VStack {
                    Spacer()
                    VStack(spacing: 9) {
                        HStack(spacing: 8) {
                            TextField(karen.showResponsePanel ? "Ask a follow-up or type a new question…" : "Type a message or question…", text: $typedInput)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .onSubmit(submitTypedInput)
                                .accessibilityLabel("Message K.A.R.E.N.")
                            Button(action: submitTypedInput) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(KarenTheme.accent(for: karen.orbState))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Send message")
                        }
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(KarenTheme.accent(for: karen.orbState).opacity(0.22), lineWidth: 1))
                        .padding(.horizontal, 40)

                        HUDBar()
                    }
                    .padding(.bottom, 20)
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
        }
        .onAppear {
            karen.setWindowOpener { openWindow(id: "main") }
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

    private func submitTypedInput() {
        let value = typedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        typedInput = ""
        karen.sendTextInput(value)
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
                Label(karen.isGesturePaused ? "Camera Paused" : "Camera",
                      systemImage: karen.isGesturePaused ? "video.slash.fill" : "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(karen.isGesturePaused ? Color(white: 0.6) : KarenTheme.accent(for: karen.orbState))
                    .accessibilityLabel(karen.isGesturePaused ? "Camera gesture control is paused" : "Camera is active")
            }

            Spacer()

            // Reset orb
            HUDButton(icon: "arrow.uturn.backward.circle", label: "Reset",
                      active: false, tint: .white) {
                karen.resetOrb()
            }
            .accessibilityLabel("Reset orb view")

            HUDButton(icon: karen.selectedImageLabels.isEmpty ? "photo" : "photo.fill",
                      label: karen.selectedImageLabels.isEmpty ? "Image" : "Ready",
                      active: !karen.selectedImageLabels.isEmpty, tint: .white) {
                karen.chooseImageInput()
            }
            .accessibilityLabel(karen.selectedImageLabels.isEmpty ? "Choose an image" : "Replace selected image")

            if !karen.selectedImageLabels.isEmpty {
                HUDButton(icon: "xmark.circle", label: "Clear", active: false, tint: .white) {
                    karen.clearImageInput()
                }
                .accessibilityLabel("Clear selected image context")
            }

            // Memory
            HUDButton(icon: "brain", label: "Memory", active: false, tint: .white) {
                karen.openMemoryMap()
            }

            // Settings
            HUDButton(icon: "gear", label: "Settings", active: false, tint: .white) {
                karen.requestOpenSettings()
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

// ─── Live Listening Indicator ────────────────────────────────────────────────

struct LiveListeningIndicator: View {
    @EnvironmentObject var karen: KarenCore

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing mic / waveform meter
            HStack(spacing: 3) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(KarenTheme.accent(for: .listening))
                        .frame(width: 3, height: waveformHeight(for: index))
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                if !karen.liveTranscription.isEmpty {
                    Text(karen.liveTranscription)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                } else {
                    Text("Listening…")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(KarenTheme.accent(for: .listening))
                    Text("Speak your question or say 'Hey Karen'")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.015, green: 0.025, blue: 0.05).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(KarenTheme.accent(for: .listening).opacity(0.45), lineWidth: 1.2)
        )
        .shadow(color: KarenTheme.accent(for: .listening).opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: 480)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: karen.liveTranscription)
    }

    private func waveformHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 6
        let amp = CGFloat(karen.audioLevel) * 22
        let multiplier: CGFloat = [0.6, 1.0, 0.8, 0.5][index % 4]
        return max(base, min(24, base + amp * multiplier))
    }
}

// ─── Thinking Pulse Badge ─────────────────────────────────────────────────────

struct ThinkingPulseBadge: View {
    @EnvironmentObject var karen: KarenCore
    @State private var animPhase: CGFloat = 0.0

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(KarenTheme.accent(for: .processing))
                        .frame(width: 5, height: 5)
                        .scaleEffect(dotScale(for: i))
                        .opacity(dotOpacity(for: i))
                }
            }

            Text("Thinking…")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(KarenTheme.accent(for: .processing))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(red: 0.02, green: 0.03, blue: 0.06).opacity(0.88))
        )
        .overlay(
            Capsule()
                .strokeBorder(KarenTheme.accent(for: .processing).opacity(0.4), lineWidth: 1)
        )
        .shadow(color: KarenTheme.accent(for: .processing).opacity(0.3), radius: 10, y: 3)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                animPhase = 1.0
            }
        }
    }

    private func dotScale(for index: Int) -> CGFloat {
        let offset = CGFloat(index) * 0.3
        let val = sin((animPhase + offset) * .pi)
        return 0.7 + max(0, val) * 0.5
    }

    private func dotOpacity(for index: Int) -> Double {
        let offset = CGFloat(index) * 0.3
        let val = sin((animPhase + offset) * .pi)
        return 0.4 + Double(max(0, val)) * 0.6
    }
}

// ─── Glowing Orb Connector ───────────────────────────────────────────────────

struct GlowingOrbConnector: View {
    @EnvironmentObject var karen: KarenCore
    @State private var pulse: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Top emitter node (touching the bottom edge of the orb)
            Circle()
                .fill(KarenTheme.accent(for: karen.orbState))
                .frame(width: 5, height: 5)
                .shadow(color: KarenTheme.accent(for: karen.orbState), radius: 6)

            // Neon energy beam with layered glow
            ZStack {
                // Wide ambient glow
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                KarenTheme.accent(for: karen.orbState).opacity(0.65),
                                KarenTheme.accent(for: karen.orbState).opacity(0.25)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 6, height: 26)
                    .blur(radius: 3)

                // Crisp central laser core
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white,
                                KarenTheme.accent(for: karen.orbState)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2, height: 26)
                    .opacity(pulse ? 1.0 : 0.75)
            }

            // Bottom receiver node (touching the top of the response card)
            Circle()
                .fill(KarenTheme.accent(for: karen.orbState).opacity(0.85))
                .frame(width: 4, height: 4)
                .shadow(color: KarenTheme.accent(for: karen.orbState), radius: 4)
        }
        .frame(height: 32)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// ─── Dynamic Response Panel ───────────────────────────────────────────────────

struct DynamicResponsePanel: View {
    @EnvironmentObject var karen: KarenCore
    @State private var showCopiedAlert: Bool = false

    private var fullText: String { karen.replyText }

    private var displayedText: String {
        guard !fullText.isEmpty else { return "" }
        if !karen.isSpeaking && karen.orbState != .speaking {
            return fullText
        }
        let count = min(karen.responseTextRevealedCount, fullText.count)
        guard count > 0 else { return "" }
        let index = fullText.index(fullText.startIndex, offsetBy: count)
        return String(fullText[..<index])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header with status indicator and Close button
            headerView

            // Question section (visually distinct with smooth animation)
            if !karen.lastUserQuery.isEmpty {
                QuestionCard(query: karen.lastUserQuery, orbState: karen.orbState)
            }

            Divider().opacity(0.18)

            // Answer body with synchronized reveal, long response scrolling, and stable layout
            if karen.orbState == .processing && fullText.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(KarenTheme.accent(for: .processing))
                    Text("Formulating response…")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
            } else {
                AnswerScrollArea(
                    displayedText: displayedText,
                    fullText: fullText,
                    isSpeaking: karen.isSpeaking || karen.orbState == .speaking,
                    orbState: karen.orbState
                )
            }

            Divider().opacity(0.18)

            // Bottom action controls: Copy, Replay, Stop Speaking, Ask Follow-up
            ResponseControlBar(
                fullText: fullText,
                isSpeaking: karen.isSpeaking || karen.orbState == .speaking || (karen.ttsEngine?.isSpeaking ?? false),
                showCopiedAlert: showCopiedAlert,
                orbState: karen.orbState,
                onCopy: copyToClipboard,
                onReplay: { karen.replayLastResponse() },
                onStop: { karen.stopSpeaking() },
                onFollowUp: { karen.askFollowUp() }
            )
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.012, green: 0.018, blue: 0.038).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(KarenTheme.accent(for: karen.orbState).opacity(0.32), lineWidth: 1)
        )
        .shadow(color: KarenTheme.accent(for: karen.orbState).opacity(0.18), radius: 24, y: 8)
        .frame(maxWidth: 580)
    }

    private var headerView: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KarenTheme.accent(for: karen.orbState))
                Text("K.A.R.E.N.")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(KarenTheme.accent(for: karen.orbState))
            }

            Spacer()

            if karen.isSpeaking || karen.orbState == .speaking {
                HStack(spacing: 5) {
                    Circle()
                        .fill(KarenTheme.accent(for: .speaking))
                        .frame(width: 6, height: 6)
                    Text("Speaking…")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(KarenTheme.accent(for: .speaking))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(KarenTheme.accent(for: .speaking).opacity(0.12), in: Capsule())
            } else if karen.orbState == .processing {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(KarenTheme.accent(for: .processing))
                    Text("Thinking…")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(KarenTheme.accent(for: .processing))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(KarenTheme.accent(for: .processing).opacity(0.12), in: Capsule())
            }

            Button(action: { karen.dismissResponsePanel() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(white: 0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss response")
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private func copyToClipboard() {
        guard !fullText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullText, forType: .string)
        withAnimation { showCopiedAlert = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { showCopiedAlert = false }
        }
    }
}

// ─── Question Card ─────────────────────────────────────────────────────────────

struct QuestionCard: View {
    let query: String
    let orbState: OrbState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(KarenTheme.accent(for: orbState))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("YOU")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(KarenTheme.accent(for: orbState).opacity(0.85))
                Text(query)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(KarenTheme.accent(for: orbState).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(KarenTheme.accent(for: orbState).opacity(0.22), lineWidth: 1)
        )
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity
        ))
    }
}

// ─── Answer Scroll Area ───────────────────────────────────────────────────────

struct AnswerScrollArea: View {
    let displayedText: String
    let fullText: String
    let isSpeaking: Bool
    let orbState: OrbState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if isSpeaking && displayedText.count < fullText.count {
                        (Text(displayedText)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundColor(.white)
                        +
                        Text(" ▍")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(KarenTheme.accent(for: orbState)))
                        .lineSpacing(4)
                    } else {
                        Text(displayedText)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .lineSpacing(4)
                            .foregroundStyle(.white)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottomScrollAnchor")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 80, maxHeight: 220)
            .onChange(of: displayedText) { _, _ in
                if isSpeaking {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottomScrollAnchor", anchor: .bottom)
                    }
                }
            }
        }
    }
}

// ─── Response Control Bar ─────────────────────────────────────────────────────

struct ResponseControlBar: View {
    let fullText: String
    let isSpeaking: Bool
    let showCopiedAlert: Bool
    let orbState: OrbState
    let onCopy: () -> Void
    let onReplay: () -> Void
    let onStop: () -> Void
    let onFollowUp: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCopy) {
                HStack(spacing: 5) {
                    Image(systemName: showCopiedAlert ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                    Text(showCopiedAlert ? "Copied!" : "Copy")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(showCopiedAlert ? KarenTheme.accent(for: .listening) : .white)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(fullText.isEmpty)
            .accessibilityLabel("Copy answer to clipboard")

            Button(action: onReplay) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("Replay")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(fullText.isEmpty || isSpeaking)
            .accessibilityLabel("Replay response")

            if isSpeaking {
                Button(action: onStop) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                        Text("Stop Speaking")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.4))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop speaking")
            }

            Spacer()

            Button(action: onFollowUp) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                    Text("Ask Follow-up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(KarenTheme.accent(for: orbState))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(KarenTheme.accent(for: orbState).opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(KarenTheme.accent(for: orbState).opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask follow-up question")
        }
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
