// SoundManager.swift
// Handles loading and playing of keyboard and mouse click sounds.
// Uses AVAudioPlayer for low‑latency playback and a simple pooling mechanism.

import Foundation
import AVFoundation
import AppKit

/// Represents a single playable sound.
struct SoundClip {
    let url: URL
    var player: AVAudioPlayer?
    init(url: URL) {
        self.url = url
        // Prepare player eagerly to reduce latency.
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.prepareToPlay()
            self.player = player
        }
    }
    mutating func play(volume: Float) {
        guard let player = player else { return }
        player.volume = volume
        // Reset to start.
        player.currentTime = 0
        player.play()
    }
}

/// Central manager for keyboard and mouse sound playback.
final class SoundManager {
    // MARK: - Public configuration
    var keyboardVolume: Float = 0.5 // 0.0 – 1.0
    var mouseVolume: Float = 0.5
    var isKeyboardEnabled: Bool = true
    var isMouseEnabled: Bool = true

    // MARK: - Internal storage
    private var keyDownClip: SoundClip?
    private var mouseClickClip: SoundClip?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init() {
        loadDefaultSounds()
        startEventTap()
    }

    deinit {
        stopEventTap()
    }

    // MARK: - Loading sounds
    private func loadDefaultSounds() {
        // Expect bundled sounds in the app bundle under "Sounds".
        if let keyURL = Bundle.main.url(forResource: "key", withExtension: "wav", subdirectory: "Sounds") {
            keyDownClip = SoundClip(url: keyURL)
        }
        if let mouseURL = Bundle.main.url(forResource: "mouse", withExtension: "wav", subdirectory: "Sounds") {
            mouseClickClip = SoundClip(url: mouseURL)
        }
    }

    // MARK: - Event tap
    private func startEventTap() {
        // Request Input Monitoring permission if needed.
        // The permission dialog is handled elsewhere (SettingsView).
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            let manager = Unmanaged<SoundManager>.fromOpaque(refcon!).takeUnretainedValue()
            manager.handle(event: event, type: type)
            return Unmanaged.passUnretained(event)
        }
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: refcon) else {
            NSLog("SoundManager: Failed to create event tap – missing Input Monitoring permission?")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event handling
    private func handle(event: CGEvent, type: CGEventType) {
        switch type {
        case .keyDown:
            if isKeyboardEnabled {
                keyDownClip?.play(volume: keyboardVolume)
            }
        case .leftMouseDown, .rightMouseDown:
            if isMouseEnabled {
                mouseClickClip?.play(volume: mouseVolume)
            }
        default:
            break
        }
    }
}

