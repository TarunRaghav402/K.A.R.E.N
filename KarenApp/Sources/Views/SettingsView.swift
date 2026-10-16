import SwiftUI
import AVFoundation

// ─── Settings View ────────────────────────────────────────────────────────────

struct SettingsView: View {
    @EnvironmentObject var karen: KarenCore
    @Environment(\.dismiss) var dismiss

    @State private var selectedVoiceId: String = AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized ? "" : ""
    @State private var voiceRate: Float  = 0.50
    @State private var voicePitch: Float = 1.05
    @State private var previewText = "Hello, I'm K.A.R.E.N. How can I help you today?"

    private var femaleVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { $0.name.contains("Samantha") || $0.name.contains("Ava") ||
                      $0.name.contains("Karen") || $0.name.contains("Moira") ||
                      $0.name.contains("Fiona") || $0.gender == .female }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(20)
            .background(KarenTheme.panel(for: karen.orbState))

            ScrollView {
                VStack(spacing: 24) {
                    // Voice settings
                    SettingsSection(title: "Voice") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Select Voice")
                                .settingsLabel()
                            Picker("Voice", selection: $selectedVoiceId) {
                                ForEach(femaleVoices, id: \.identifier) { v in
                                    Text(v.name).tag(v.identifier)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: selectedVoiceId) { _, id in
                                karen.ttsEngine?.voiceId = id
                            }

                            LabeledSlider(label: "Rate", value: $voiceRate, range: 0.1...1.0) {
                                karen.ttsEngine?.rate = voiceRate
                            }
                            LabeledSlider(label: "Pitch", value: $voicePitch, range: 0.5...2.0) {
                                karen.ttsEngine?.pitch = voicePitch
                            }

                            Button("Preview Voice") {
                                karen.ttsEngine?.speak(previewText)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(KarenTheme.accent(for: karen.orbState))
                        }
                    }

                    // Response mode
                    SettingsSection(title: "Response Mode") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Text Only (no speech)", isOn: $karen.isTextOnly)
                                .toggleStyle(.switch)
                            Toggle("Mute Responses", isOn: $karen.isMuted)
                                .toggleStyle(.switch)
                        }
                    }

                    // Wake word
                    SettingsSection(title: "Wake Word") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Enable \"Hey Karen\" wake word", isOn: $karen.wakeWordEnabled)
                                .toggleStyle(.switch)
                                .onChange(of: karen.wakeWordEnabled) { _, v in
                                    if v { karen.wakeWordDetector?.start() }
                                    else { karen.wakeWordDetector?.stop() }
                                }
                            Text("Wake word detection runs entirely on-device. Audio never leaves your Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Privacy notice
                    SettingsSection(title: "Privacy") {
                        Text("K.A.R.E.N. processes all speech on-device. No audio is transmitted unless you configure an external LLM provider. Memory is stored locally and requires your approval.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 520)
        .background(KarenTheme.backdrop(for: karen.orbState)[0])
        .foregroundStyle(.white)
    }
}

// ─── Permissions Center ───────────────────────────────────────────────────────

struct PermissionsCenterView: View {
    @EnvironmentObject var karen: KarenCore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Permissions")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(20)
            .background(KarenTheme.panel(for: karen.orbState))

            ScrollView {
                VStack(spacing: 16) {
                    PermissionRow(
                        title: "Microphone",
                        reason: "Required to hear your voice commands. Used only while listening — never recorded.",
                        icon: "mic.fill",
                        granted: karen.micGranted,
                        active: karen.isListening
                    ) { karen.requestMic() }

                    PermissionRow(
                        title: "Speech Recognition",
                        reason: "Converts speech to text on-device using Apple's Speech framework.",
                        icon: "waveform",
                        granted: karen.speechGranted,
                        active: karen.isListening
                    ) { karen.requestSpeechRecognition() }

                    PermissionRow(
                        title: "Camera",
                        reason: "Used only for two-hand gesture control. Camera is off when gesture mode is disabled.",
                        icon: "camera.fill",
                        granted: karen.cameraGranted,
                        active: karen.cameraActive
                    ) { karen.requestCamera() }

                    PermissionRow(
                        title: "Local Memory Storage",
                        reason: "Memories are kept in K.A.R.E.N.’s private Application Support folder. macOS does not require a separate storage permission for this app-owned data.",
                        icon: "internaldrive.fill",
                        granted: true,
                        active: true
                    ) {}

                    Divider().opacity(0.2)

                    Button("Revoke permissions in System Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                    }
                    .font(.callout)
                    .foregroundStyle(KarenTheme.accent(for: karen.orbState))
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 460)
        .background(KarenTheme.backdrop(for: karen.orbState)[0])
        .foregroundStyle(.white)
    }
}

struct PermissionRow: View {
    @EnvironmentObject var karen: KarenCore
    let title: String
    let reason: String
    let icon: String
    let granted: Bool
    let active: Bool
    let request: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(granted ? KarenTheme.accent(for: karen.orbState) : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if active {
                        Label("Active", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(KarenTheme.accent(for: karen.orbState))
                    }
                }
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !granted {
                    Button("Grant Access") { request() }
                        .buttonStyle(.borderedProminent)
                        .tint(KarenTheme.accent(for: karen.orbState))
                        .font(.caption)
                        .padding(.top, 4)
                } else {
                    Text("✓ Granted")
                        .font(.caption)
                        .foregroundStyle(KarenTheme.accent(for: karen.orbState))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(KarenTheme.panel(for: karen.orbState)))
    }
}

// ─── Memory view ──────────────────────────────────────────────────────────────

struct MemoryView: View {
    @EnvironmentObject var karen: KarenCore
    @Environment(\.dismiss) var dismiss
    @State private var memories: [MemoryMapNode] = []
    @State private var selectedMemory: MemoryMapNode?
    @State private var draftMemory = ""

    private let nucleusID = "memory-nucleus"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Memory Core")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("One connected node for every saved memory")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(KarenTheme.panel(for: karen.orbState))

            GeometryReader { geometry in
                ZStack {
                    Color(red: 0.004, green: 0.007, blue: 0.018)
                    MemoryNeuralLinks(count: memories.count)
                    Circle()
                        .fill(RadialGradient(colors: [KarenTheme.accent(for: karen.orbState).opacity(0.36), .clear],
                                             center: .center, startRadius: 2, endRadius: 95))
                        .frame(width: 190, height: 190)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    Circle()
                        .fill(Color(red: 0.045, green: 0.075, blue: 0.14))
                        .overlay(Circle().stroke(KarenTheme.accent(for: karen.orbState).opacity(0.86), lineWidth: 1.5))
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 27, weight: .light))
                                Text("NUCLEUS")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                Text("\(memories.count) memories")
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.62))
                            }
                            .foregroundStyle(.white)
                        }
                        .frame(width: 92, height: 92)
                        .shadow(color: KarenTheme.accent(for: karen.orbState).opacity(0.26), radius: 18)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                    ForEach(Array(memories.enumerated()), id: \.element.id) { index, memory in
                        let position = nodePosition(index: index, count: memories.count, size: geometry.size)
                        Button {
                            selectedMemory = memory
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(KarenTheme.accent(for: karen.orbState))
                                    .frame(width: 7, height: 7)
                                Text(memory.content)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(red: 0.025, green: 0.04, blue: 0.075), in: Capsule())
                            .overlay(Capsule().stroke(KarenTheme.accent(for: karen.orbState).opacity(0.45), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .help(memory.content)
                        .position(x: position.x, y: position.y)
                    }

                    if let selectedMemory {
                        VStack(spacing: 8) {
                            HStack {
                                Text("MEMORY NODE").font(.caption2.bold()).tracking(1.1)
                                Spacer()
                                Button { self.selectedMemory = nil } label: {
                                    Image(systemName: "xmark.circle.fill").font(.title3)
                                }
                                .buttonStyle(.plain)
                            }
                            Text(selectedMemory.content)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Text(selectedMemory.createdAt)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.white.opacity(0.56))
                                Spacer()
                                Button(role: .destructive) {
                                    karen.sidecarBridge?.memory?.delete(selectedMemory.id)
                                    self.selectedMemory = nil
                                    loadMemories()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(13)
                        .frame(width: 320)
                        .background(KarenTheme.panel(for: karen.orbState), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(KarenTheme.accent(for: karen.orbState).opacity(0.5), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 16)
                    } else if memories.isEmpty {
                        VStack(spacing: 7) {
                            Text("Your memory network is ready")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text("Add a memory below to create the first connected node.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        .foregroundStyle(.white)
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.79)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 10) {
                TextField("Add a memory to the network…", text: $draftMemory)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(addMemory)
                Button(action: addMemory) {
                    Label("Add Memory", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(KarenTheme.accent(for: karen.orbState))
                .disabled(draftMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 820, height: 610)
        .background(Color(red: 0.004, green: 0.007, blue: 0.018))
        .foregroundStyle(.white)
        .onAppear { loadMemories() }
    }

    func loadMemories() {
        memories = (karen.sidecarBridge?.memory?.list_approved().map { row in
            MemoryMapNode(id: row["id"] as? String ?? UUID().uuidString,
                          content: row["content"] as? String ?? "",
                          createdAt: row["created_at"] as? String ?? "")
        }) ?? []
        karen.refreshMemoryNodeLabels()
    }

    private func addMemory() {
        guard let store = karen.sidecarBridge?.memory else { return }
        store.add_approved(draftMemory)
        draftMemory = ""
        loadMemories()
    }

    private func nodePosition(index: Int, count: Int, size: CGSize) -> CGPoint {
        let ring = index / 12
        let slot = index % 12
        let slotsInRing = min(12, count - ring * 12)
        let angle = (Double(slot) / Double(max(slotsInRing, 1))) * 2 * Double.pi - Double.pi / 2 + Double(ring) * 0.22
        let radius = min(0.43, 0.24 + Double(ring) * 0.13)
        return CGPoint(x: size.width * (0.5 + cos(angle) * radius),
                       y: size.height * (0.5 + sin(angle) * radius))
    }
}

private struct MemoryMapNode: Identifiable {
    let id: String
    let content: String
    let createdAt: String
}

private struct MemoryNeuralLinks: View {
    @EnvironmentObject var karen: KarenCore
    let count: Int

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var links = Path()
            for index in 0..<count {
                let ring = index / 12
                let slot = index % 12
                let slots = min(12, count - ring * 12)
                let angle = Double(slot) / Double(max(slots, 1)) * 2 * Double.pi - Double.pi / 2 + Double(ring) * 0.22
                let radius = min(0.43, 0.24 + Double(ring) * 0.13)
                let point = CGPoint(x: size.width * (0.5 + cos(angle) * radius),
                                    y: size.height * (0.5 + sin(angle) * radius))
                links.move(to: center)
                links.addLine(to: point)
                if slots > 1 {
                    let nextAngle = Double((slot + 1) % slots) / Double(slots) * 2 * Double.pi - Double.pi / 2 + Double(ring) * 0.22
                    let next = CGPoint(x: size.width * (0.5 + cos(nextAngle) * radius),
                                       y: size.height * (0.5 + sin(nextAngle) * radius))
                    links.move(to: point)
                    links.addLine(to: next)
                }
            }
            context.stroke(links, with: .color(KarenTheme.accent(for: karen.orbState).opacity(0.36)), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

struct SettingsSection<Content: View>: View {
    @EnvironmentObject var karen: KarenCore
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(KarenTheme.accent(for: karen.orbState))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(KarenTheme.panel(for: karen.orbState)))
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var onChange: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading)
            Slider(value: $value, in: range)
                .onChange(of: value) { _, _ in onChange?() }
            Text(String(format: "%.2f", value))
                .font(.caption.monospaced())
                .frame(width: 42)
        }
    }
}

extension Text {
    func settingsLabel() -> some View {
        self.font(.subheadline).foregroundStyle(.secondary)
    }
}
