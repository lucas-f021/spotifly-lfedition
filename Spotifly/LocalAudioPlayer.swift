//
//  LocalAudioPlayer.swift
//  Spotifly
//
//  Plays local audio files via AVAudioEngine + AVAudioUnitEQ, separate from Spirc/librespot.
//

import AVFoundation
import Combine
import Foundation

@MainActor
@Observable
final class LocalAudioPlayer {
    static let shared = LocalAudioPlayer()

    private(set) var isPlaying = false
    private(set) var currentFileURL: URL?
    private(set) var duration: Double = 0 // seconds
    private(set) var position: Double = 0 // seconds

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: Equalizer.bandCount)
    private var audioFile: AVAudioFile?
    private var positionTimer: Timer?
    /// Sample rate of the current file (for position calculation)
    private var sampleRate: Double = 44100
    /// Frame position when playback last started/resumed
    private var startingFrame: AVAudioFramePosition = 0

    private init() {
        setupEngine()
        syncEQFromEqualizer()
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(eq)
        // Chain: playerNode → EQ → mainMixer → output
        // Format will be connected per-file in play()
    }

    /// Syncs AVAudioUnitEQ bands from the app's Equalizer (shared via AudioRenderer).
    func syncEQFromEqualizer() {
        let equalizer = sharedEqualizer
        let enabled = equalizer.isEnabled

        for i in 0 ..< Equalizer.bandCount {
            let band = eq.bands[i]
            let eqBand = Equalizer.bands[i]

            band.frequency = eqBand.frequency
            band.bandwidth = 1.0 // octave
            band.gain = enabled ? equalizer.gain(forBand: i) : 0
            band.bypass = !enabled

            switch eqBand.type {
            case .lowShelf:
                band.filterType = .lowShelf
            case .peaking:
                band.filterType = .parametric
            case .highShelf:
                band.filterType = .highShelf
            }
        }
    }

    // MARK: - Playback

    /// Plays a local audio file.
    func play(url: URL) throws {
        stop()

        let file = try AVAudioFile(forReading: url)
        audioFile = file
        sampleRate = file.processingFormat.sampleRate
        duration = Double(file.length) / sampleRate
        startingFrame = 0

        // Connect with the file's format
        let format = file.processingFormat
        engine.connect(playerNode, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)

        try engine.start()

        playerNode.scheduleFile(file, at: nil)
        playerNode.play()

        currentFileURL = url
        isPlaying = true
        startPositionTimer()
    }

    /// Resumes playback if paused.
    func resume() {
        guard !isPlaying, audioFile != nil else { return }
        playerNode.play()
        isPlaying = true
        startPositionTimer()
    }

    /// Pauses playback.
    func pause() {
        playerNode.pause()
        isPlaying = false
        stopPositionTimer()
    }

    /// Stops playback and resets state.
    func stop() {
        playerNode.stop()
        engine.stop()
        // Disconnect to allow reconnecting with different format
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(eq)
        audioFile = nil
        isPlaying = false
        currentFileURL = nil
        duration = 0
        position = 0
        startingFrame = 0
        stopPositionTimer()
    }

    /// Seeks to a position in seconds.
    func seek(to seconds: Double) {
        guard let file = audioFile else { return }

        let wasPlaying = isPlaying
        playerNode.stop()

        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        let clampedFrame = max(0, min(targetFrame, file.length))
        let remainingFrames = AVAudioFrameCount(file.length - clampedFrame)

        guard remainingFrames > 0 else { return }

        file.framePosition = clampedFrame
        startingFrame = clampedFrame

        playerNode.scheduleSegment(
            file,
            startingFrame: clampedFrame,
            frameCount: remainingFrames,
            at: nil
        )

        position = seconds

        if wasPlaying {
            playerNode.play()
        }
    }

    /// Sets volume (0.0–1.0).
    func setVolume(_ volume: Float) {
        playerNode.volume = volume
    }

    // MARK: - Position Timer

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePosition()
            }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func updatePosition() {
        guard isPlaying, let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return }

        let currentFrame = startingFrame + playerTime.sampleTime
        position = Double(currentFrame) / sampleRate

        // Detect end of file
        if let file = audioFile, currentFrame >= file.length {
            isPlaying = false
            position = 0
            stopPositionTimer()
            NotificationCenter.default.post(name: .localFileDidFinishPlaying, object: nil)
        }
    }
}

extension Notification.Name {
    static let localFileDidFinishPlaying = Notification.Name("localFileDidFinishPlaying")
}
