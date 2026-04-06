//
//  Equalizer.swift
//  Spotifly
//
//  6-band graphic EQ applied to the PCM stream in AudioRenderer.feedRenderer().
//  DSP: vDSP_biquad (hardware-accelerated SIMD) with RBJ Audio EQ Cookbook coefficients.
//  Thread safety: NSLock guards coefficients + state.
//

import Accelerate
import Foundation

// MARK: - Equalizer

final class Equalizer: @unchecked Sendable {
    // MARK: - Band Definitions

    enum FilterType { case lowShelf, peaking, highShelf }

    struct Band {
        let frequency: Float
        let type: FilterType
    }

    nonisolated(unsafe) static let bands: [Band] = [
        Band(frequency: 60, type: .lowShelf),
        Band(frequency: 150, type: .peaking),
        Band(frequency: 400, type: .peaking),
        Band(frequency: 1000, type: .peaking),
        Band(frequency: 2400, type: .peaking),
        Band(frequency: 15000, type: .highShelf),
    ]

    nonisolated(unsafe) static let bandCount = 6
    nonisolated(unsafe) static let gainRange: ClosedRange<Float> = -12 ... 12

    // MARK: - State

    nonisolated(unsafe) private let lock = NSLock()
    nonisolated(unsafe) private(set) var isEnabled: Bool
    nonisolated(unsafe) private var gains: [Float]

    /// vDSP biquad setups — one per band per channel (L/R)
    nonisolated(unsafe) private var setupsL: [vDSP_biquad_Setup?]
    nonisolated(unsafe) private var setupsR: [vDSP_biquad_Setup?]
    /// Delay state for vDSP_biquad: 2 sections × (2+1) = array of length 6 per setup,
    /// but we use single-section so length 2+1 = 3... actually vDSP needs 2*2+2 = 6 per section.
    /// For 1 section: delays array must have at least 2*2+2 = 6 elements.
    nonisolated(unsafe) private var delaysL: [[Float]]
    nonisolated(unsafe) private var delaysR: [[Float]]

    /// Scratch buffers for deinterleaving (reused across calls)
    nonisolated(unsafe) private var scratchL: [Float] = []
    nonisolated(unsafe) private var scratchR: [Float] = []
    /// Temp buffer for vDSP_biquad (needs separate in/out for exclusivity)
    nonisolated(unsafe) private var tempBuf: [Float] = []

    private nonisolated(unsafe) static let sampleRate: Float = 44100
    private nonisolated(unsafe) static let peakingQ: Float = 1.0
    private nonisolated(unsafe) static let shelfSlope: Float = 1.0

    // MARK: - Init

    nonisolated init() {
        gains = [Float](repeating: 0, count: Self.bandCount)
        isEnabled = false
        setupsL = []
        setupsR = []
        delaysL = []
        delaysR = []
        rebuildSetups()
    }

    // MARK: - Public API

    nonisolated func setGain(_ gain: Float, forBand index: Int) {
        guard (0 ..< Self.bandCount).contains(index) else { return }
        let clamped = max(Self.gainRange.lowerBound, min(Self.gainRange.upperBound, gain))
        lock.lock()
        gains[index] = clamped
        rebuildSetups()
        lock.unlock()
    }

    nonisolated func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        if !enabled {
            resetDelays()
        }
        lock.unlock()
    }

    nonisolated func gain(forBand index: Int) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return gains[index]
    }

    nonisolated func reset() {
        lock.lock()
        gains = [Float](repeating: 0, count: Self.bandCount)
        rebuildSetups()
        lock.unlock()
    }

    // MARK: - DSP (called from renderQueue)

    /// Process an interleaved stereo Float32 buffer in-place.
    /// `count` is the total number of floats (frames × 2 channels).
    @inline(__always)
    nonisolated func process(_ ptr: UnsafeMutablePointer<Float>, count: Int) {
        guard isEnabled else { return }

        lock.lock()
        defer { lock.unlock() }

        let frameCount = count / 2

        // Ensure scratch buffers are large enough
        if scratchL.count < frameCount {
            scratchL = [Float](repeating: 0, count: frameCount)
            scratchR = [Float](repeating: 0, count: frameCount)
            tempBuf = [Float](repeating: 0, count: frameCount)
        }

        // Deinterleave: LRLRLR → L,L,L + R,R,R
        var splitComplex = DSPSplitComplex(
            realp: &scratchL,
            imagp: &scratchR
        )
        let complexPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: DSPComplex.self)
        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(frameCount))

        // Apply each biquad band using temp buffer to avoid exclusivity conflict
        for i in 0 ..< Self.bandCount {
            guard let setupL = setupsL[i], let setupR = setupsR[i] else { continue }

            vDSP_biquad(setupL, &delaysL[i], &scratchL, 1, &tempBuf, 1, vDSP_Length(frameCount))
            scratchL = tempBuf

            vDSP_biquad(setupR, &delaysR[i], &scratchR, 1, &tempBuf, 1, vDSP_Length(frameCount))
            scratchR = tempBuf
        }

        // Interleave back: L,L,L + R,R,R → LRLRLR
        splitComplex = DSPSplitComplex(realp: &scratchL, imagp: &scratchR)
        let outComplex = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: DSPComplex.self)
        vDSP_ztoc(&splitComplex, 1, outComplex, 2, vDSP_Length(frameCount))
    }

    // MARK: - Setup

    /// Rebuilds vDSP_biquad setups from current gains. Must be called under lock.
    private nonisolated func rebuildSetups() {
        // Destroy old setups
        for setup in setupsL { if let s = setup { vDSP_biquad_DestroySetup(s) } }
        for setup in setupsR { if let s = setup { vDSP_biquad_DestroySetup(s) } }

        setupsL = (0 ..< Self.bandCount).map { i in
            Self.createSetup(type: Self.bands[i].type, frequency: Self.bands[i].frequency, gainDB: gains[i])
        }
        setupsR = (0 ..< Self.bandCount).map { i in
            Self.createSetup(type: Self.bands[i].type, frequency: Self.bands[i].frequency, gainDB: gains[i])
        }

        // Reset delay state
        resetDelays()
    }

    private nonisolated func resetDelays() {
        delaysL = (0 ..< Self.bandCount).map { _ in [Float](repeating: 0, count: 2 + 2) }
        delaysR = (0 ..< Self.bandCount).map { _ in [Float](repeating: 0, count: 2 + 2) }
    }

    // MARK: - Coefficient Math (RBJ Audio EQ Cookbook)

    /// Creates a vDSP_biquad_Setup with coefficients for the given filter type.
    /// Coefficients: [b0, b1, b2, a1, a2] (a0 normalized to 1.0)
    private nonisolated static func createSetup(type: FilterType, frequency: Float, gainDB: Float) -> vDSP_biquad_Setup? {
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let A = pow(10.0, gainDB / 40.0)

        let b0, b1, b2, a0, a1, a2: Float

        switch type {
        case .peaking:
            let alpha = sinW0 / (2 * peakingQ)
            b0 = 1 + alpha * A
            b1 = -2 * cosW0
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosW0
            a2 = 1 - alpha / A

        case .lowShelf:
            let sqrtA = sqrt(A)
            let alpha = sinW0 / 2 * sqrt((A + 1 / A) * (1 / shelfSlope - 1) + 2)
            b0 = A * ((A + 1) - (A - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW0)
            b2 = A * ((A + 1) - (A - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 = (A + 1) + (A - 1) * cosW0 + 2 * sqrtA * alpha
            a1 = -2 * ((A - 1) + (A + 1) * cosW0)
            a2 = (A + 1) + (A - 1) * cosW0 - 2 * sqrtA * alpha

        case .highShelf:
            let sqrtA = sqrt(A)
            let alpha = sinW0 / 2 * sqrt((A + 1 / A) * (1 / shelfSlope - 1) + 2)
            b0 = A * ((A + 1) + (A - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
            b2 = A * ((A + 1) + (A - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 = (A + 1) - (A - 1) * cosW0 + 2 * sqrtA * alpha
            a1 = 2 * ((A - 1) - (A + 1) * cosW0)
            a2 = (A + 1) - (A - 1) * cosW0 - 2 * sqrtA * alpha
        }

        // Normalize and create coefficients array for vDSP
        // vDSP_biquad expects: [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
        var coefficients: [Double] = [
            Double(b0 / a0),
            Double(b1 / a0),
            Double(b2 / a0),
            Double(a1 / a0),
            Double(a2 / a0),
        ]

        return vDSP_biquad_CreateSetup(&coefficients, 1)
    }
}
