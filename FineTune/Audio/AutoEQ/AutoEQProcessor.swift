// FineTune/Audio/AutoEQ/AutoEQProcessor.swift
import Foundation
import Accelerate
import Synchronization

/// RT-safe parametric EQ processor for AutoEQ / room correction profiles.
///
/// Supports up to `AutoEQProfile.maxFilters` biquad sections. Delay buffers for that
/// ceiling are pre-allocated, so switching between profiles with different section
/// counts never allocates on the audio thread.
///
/// ## Glitch-free profile switching
/// Profile changes (including enable/disable and preamp changes) are crossfaded over
/// `crossfadeSeconds`: for the duration of the fade the audio thread runs both the old and
/// the new cascade, each with its own delay-buffer bank, and mixes them with a linear
/// ramp. A sample-rate change is a hard cut (the old coefficients are invalid).
///
/// ## Thread model
/// - Main thread publishes `(setup, preampGain)` with an atomic seqlock (`_seq` odd while
///   writing). All cross-thread fields use `Synchronization.Atomic` with explicit
///   acquire/release ordering (lock-free, RT-safe, and Swift 6 data-race free).
///   The audio thread never blocks: if it observes a write in progress it keeps the
///   previous configuration and retries on the next callback.
/// - Replaced setups are retired on the main thread and destroyed only after the audio
///   thread acknowledges (`_rtAckSeq`) that it no longer references them — so even a
///   stalled IOProc can never touch freed memory.
///
/// Inherits from `BiquadProcessor` for API compatibility (`BiquadProcessable`,
/// `sampleRate`, logger); the base class's own setup/delay machinery is unused.
final class AutoEQProcessor: BiquadProcessor, @unchecked Sendable {

    /// Crossfade duration for profile switches.
    static let crossfadeSeconds: Double = 0.025

    /// Frames processed per chunk during a crossfade (bounds the scratch buffer).
    private static let scratchFrames = 512

    /// Currently applied profile (needed for sample rate recalculation)
    private var _currentProfile: AutoEQProfile?

    /// Read-only access to current profile
    var currentProfile: AutoEQProfile? { _currentProfile }

    /// Whether to apply the profile's preamp (false = bypass preamp, rely on limiter)
    private var _preampEnabled: Bool = true

    /// Whether the profile preamp is applied (main thread).
    var isPreampEnabled: Bool { _preampEnabled }

    // MARK: - Published state (main writes, audio reads via atomic seqlock)

    private let _seq = Atomic<UInt64>(0)
    private let _pubSetupBits = Atomic<UInt>(0)
    private let _pubGainBits = Atomic<UInt32>(Float(1.0).bitPattern)
    private let _pubHardCut = Atomic<UInt64>(0)
    private let _pubFadeFrames = Atomic<Int>(1)

    /// Highest seq whose configuration the audio thread has fully adopted (fade finished).
    private let _rtAckSeq = Atomic<UInt64>(0)

    /// Mirror of `rtCurSetup != nil || rtFading` published by the audio thread for `isEnabled`.
    private let _rtActive = Atomic<Bool>(false)

    // MARK: - Audio-thread state

    private nonisolated(unsafe) var rtSeenSeq: UInt64 = 0
    private nonisolated(unsafe) var rtSeenHardCut: UInt64 = 0
    private nonisolated(unsafe) var rtCurSetup: vDSP_biquad_Setup?
    private nonisolated(unsafe) var rtCurGain: Float = 1.0
    private nonisolated(unsafe) var rtCurBank: Int = 0
    private nonisolated(unsafe) var rtOldSetup: vDSP_biquad_Setup?
    private nonisolated(unsafe) var rtOldGain: Float = 1.0
    private nonisolated(unsafe) var rtOldBank: Int = 1
    private nonisolated(unsafe) var rtFading: Bool = false
    private nonisolated(unsafe) var rtFadePos: Int = 0
    private nonisolated(unsafe) var rtFadeLen: Int = 1

    // MARK: - Pre-allocated buffers

    /// Delay buffers: [bank][channel], each `2 * maxFilters + 2` floats.
    private let delaySize: Int
    private nonisolated(unsafe) let delay: UnsafeMutablePointer<Float>   // 4 contiguous buffers: b0L b0R b1L b1R
    private nonisolated(unsafe) let scratch: UnsafeMutablePointer<Float> // scratchFrames * 2 (stereo interleaved)

    // MARK: - Main-thread bookkeeping

    private nonisolated(unsafe) var publishedSetup: vDSP_biquad_Setup?
    private nonisolated(unsafe) var retired: [(setup: vDSP_biquad_Setup, retiredAt: UInt64)] = []
    private var reclaimScheduled = false

    init(sampleRate: Double) {
        delaySize = 2 * AutoEQProfile.maxFilters + 2
        delay = .allocate(capacity: delaySize * 4)
        delay.initialize(repeating: 0, count: delaySize * 4)
        scratch = .allocate(capacity: Self.scratchFrames * 2)
        scratch.initialize(repeating: 0, count: Self.scratchFrames * 2)
        // Base-class delay buffers are unused; keep them minimal.
        super.init(sampleRate: sampleRate, maxSections: 1, category: "AutoEQProcessor")
        _pubFadeFrames.store(Self.fadeFrames(for: sampleRate), ordering: .relaxed)
    }

    deinit {
        // The owning controller stops the IOProc before releasing processors.
        if let s = publishedSetup { vDSP_biquad_DestroySetup(s) }
        for r in retired where r.setup != publishedSetup { vDSP_biquad_DestroySetup(r.setup) }
        delay.deallocate()
        scratch.deallocate()
    }

    private static func fadeFrames(for rate: Double) -> Int {
        max(1, Int(rate * crossfadeSeconds))
    }

    @inline(__always)
    private static func encodeSetup(_ setup: vDSP_biquad_Setup?) -> UInt {
        setup.map { UInt(bitPattern: $0) } ?? 0
    }

    @inline(__always)
    private static func decodeSetup(_ bits: UInt) -> vDSP_biquad_Setup? {
        bits == 0 ? nil : vDSP_biquad_Setup(bitPattern: bits)
    }

    /// True while a profile is active or fading out. Read by the render callback.
    override var isEnabled: Bool {
        _pubSetupBits.load(ordering: .relaxed) != 0 || _rtActive.load(ordering: .relaxed)
    }

    /// Number of sections in the active profile (diagnostic / tests).
    private(set) var activeFilterCount: Int = 0

    // MARK: - Profile Update

    /// Update the correction profile (call from main thread).
    /// Pass `nil` to disable correction.
    func updateProfile(_ profile: AutoEQProfile?) {
        dispatchPrecondition(condition: .onQueue(.main))
        _currentProfile = profile
        applyCurrentProfile(hardCut: false)
    }

    /// Builds coefficients for the current profile and publishes them.
    private func applyCurrentProfile(hardCut: Bool) {
        guard let validated = _currentProfile?.validated(), !validated.filters.isEmpty else {
            publish(setup: nil, gain: 1.0, hardCut: hardCut)
            activeFilterCount = 0
            logger.info("AutoEQ disabled — \(self._currentProfile == nil ? "nil profile" : "no valid filters")")
            return
        }

        let filters = validated.filters
        guard filters.count <= AutoEQProfile.maxFilters else {
            // Never truncate: keep the previous profile active.
            logger.error("Profile \"\(validated.name)\" has \(filters.count) filters (max \(AutoEQProfile.maxFilters)) — not applied")
            return
        }

        let coefficients = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: sampleRate,
            profileOptimizedRate: validated.optimizedSampleRate
        )

        guard let newSetup = coefficients.withUnsafeBufferPointer({ ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(filters.count))
        }) else {
            // Keep the previous profile active — don't break working audio
            logger.warning("vDSP_biquad_CreateSetup returned nil for \(filters.count) filters — skipping profile update")
            return
        }

        // Preamp: dB → linear (AutoEQ preamp can be bypassed; PEQ fixedPreampDB and A/B trim always apply)
        let gainDB = (_preampEnabled ? validated.preampDB : 0) + validated.fixedPreampDB + validated.levelTrimDB
        let preampLinear = powf(10.0, gainDB / 20.0)
        publish(setup: newSetup, gain: preampLinear, hardCut: hardCut)
        activeFilterCount = filters.count

        let preampStatus = self._preampEnabled ? "active" : "bypassed"
        logger.info("AutoEQ applied: \"\(validated.name)\" — \(filters.count) filters, preamp \(validated.preampDB, format: .fixed(precision: 1)) dB (\(preampStatus)), trim \(validated.levelTrimDB, format: .fixed(precision: 1)) dB, rate \(self.sampleRate, format: .fixed(precision: 0)) Hz")
    }

    /// Seqlock publish of a new configuration. Main thread only.
    private func publish(setup: vDSP_biquad_Setup?, gain: Float, hardCut: Bool) {
        let old = publishedSetup
        publishedSetup = setup

        let startSeq = _seq.load(ordering: .relaxed)
        // Odd seq marks write-in-progress; full fence prevents any payload store from
        // reordering above the odd store on weakly-ordered architectures (ARM64).
        _seq.store(startSeq &+ 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        _pubSetupBits.store(Self.encodeSetup(setup), ordering: .relaxed)
        _pubGainBits.store(gain.bitPattern, ordering: .relaxed)
        _pubFadeFrames.store(Self.fadeFrames(for: sampleRate), ordering: .relaxed)
        if hardCut {
            let hc = _pubHardCut.load(ordering: .relaxed)
            _pubHardCut.store(hc &+ 1, ordering: .relaxed)
        }
        let endSeq = startSeq &+ 2
        // Release store prevents any payload store from sinking below the even seq store.
        _seq.store(endSeq, ordering: .releasing)

        if let old {
            retired.append((old, endSeq))
            scheduleReclaim()
        }
    }

    /// Destroys retired setups once the audio thread has moved past them.
    private func scheduleReclaim() {
        guard !reclaimScheduled else { return }
        reclaimScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.reclaimScheduled = false
            let ack = self._rtAckSeq.load(ordering: .acquiring)
            var keep: [(setup: vDSP_biquad_Setup, retiredAt: UInt64)] = []
            for r in self.retired {
                if ack >= r.retiredAt {
                    vDSP_biquad_DestroySetup(r.setup)
                } else {
                    keep.append(r)
                }
            }
            self.retired = keep
            if !keep.isEmpty { self.scheduleReclaim() }
        }
    }

    // MARK: - Preamp Mode

    /// Toggle profile preamp on/off. When off, relies on downstream limiter for peak control.
    func setPreampEnabled(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled != _preampEnabled else { return }
        _preampEnabled = enabled
        logger.info("AutoEQ preamp \(enabled ? "enabled" : "bypassed (limiter-only)")")
        if _currentProfile != nil {
            applyCurrentProfile(hardCut: false)
        }
    }

    // MARK: - Sample Rate

    override func updateSampleRate(_ newRate: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard newRate != sampleRate else { return }
        super.updateSampleRate(newRate)  // updates `sampleRate`; base setup unused
        applyCurrentProfile(hardCut: true)
    }

    /// Base-class hook: unused (this class manages its own setups).
    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        nil
    }

    // MARK: - Audio Processing (RT-safe)

    @inline(__always)
    private func bank(_ b: Int, _ ch: Int) -> UnsafeMutablePointer<Float> {
        delay.advanced(by: (b * 2 + ch) * delaySize)
    }

    @inline(__always)
    private func clearBank(_ b: Int) {
        memset(bank(b, 0), 0, delaySize * 2 * MemoryLayout<Float>.size)
    }

    /// Runs one path (preamp + cascade) in place on `buf`.
    @inline(__always)
    private func runPath(_ setup: vDSP_biquad_Setup?, gain: Float, bankIndex: Int,
                         buf: UnsafeMutablePointer<Float>, frames: Int) {
        guard let setup else { return }  // dry path
        var g = gain
        if g != 1.0 { vDSP_vsmul(buf, 1, &g, buf, 1, vDSP_Length(frames * 2)) }
        vDSP_biquad(setup, bank(bankIndex, 0), buf, 2, buf, 2, vDSP_Length(frames))
        vDSP_biquad(setup, bank(bankIndex, 1), buf.advanced(by: 1), 2, buf.advanced(by: 1), 2, vDSP_Length(frames))
    }

    /// Picks up a newly published configuration (audio thread). Non-blocking.
    /// Sample-rate hard cuts always preempt an in-progress crossfade so old-rate
    /// coefficients are never applied at the new sample rate.
    @inline(__always)
    private func pollPublished() {
        // Acquire load prevents payload loads from hoisting above the first seq check.
        let s1 = _seq.load(ordering: .acquiring)
        guard s1 != rtSeenSeq, s1 & 1 == 0 else { return }

        let setupBits = _pubSetupBits.load(ordering: .relaxed)
        let gainBits = _pubGainBits.load(ordering: .relaxed)
        let hardCut = _pubHardCut.load(ordering: .relaxed)
        let fadeFrames = _pubFadeFrames.load(ordering: .relaxed)

        // Acquire fence prevents payload loads from sinking below the second seq check on ARM64.
        atomicMemoryFence(ordering: .acquiring)
        guard _seq.load(ordering: .relaxed) == s1 else { return }  // torn read — retry next callback

        let setup = Self.decodeSetup(setupBits)
        let gain = Float(bitPattern: gainBits)

        if hardCut != rtSeenHardCut {
            rtSeenSeq = s1
            rtSeenHardCut = hardCut
            rtFading = false
            rtOldSetup = nil
            clearBank(0); clearBank(1)
            rtCurSetup = setup; rtCurGain = gain; rtCurBank = 0
            _rtActive.store(setup != nil, ordering: .relaxed)
            _rtAckSeq.store(s1, ordering: .releasing)
            return
        }

        guard !rtFading else { return }  // finish the current fade before starting a normal switch
        rtSeenSeq = s1

        if setup == rtCurSetup && gain == rtCurGain {
            _rtActive.store(rtCurSetup != nil, ordering: .relaxed)
            _rtAckSeq.store(s1, ordering: .releasing)
            return
        }

        rtOldSetup = rtCurSetup; rtOldGain = rtCurGain; rtOldBank = rtCurBank
        rtCurBank = 1 - rtCurBank
        clearBank(rtCurBank)
        rtCurSetup = setup; rtCurGain = gain
        rtFadeLen = fadeFrames
        rtFadePos = 0
        rtFading = true
        _rtActive.store(true, ordering: .relaxed)
    }

    /// Process stereo interleaved audio. RT-safe: no allocations, locks, ObjC, or I/O.
    /// Can process in-place (input == output).
    override func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }
        guard frameCount > 0 else { return }

        pollPublished()

        if !rtFading {
            runPath(rtCurSetup, gain: rtCurGain, bankIndex: rtCurBank, buf: output, frames: frameCount)
        } else {
            // Crossfade in chunks so the scratch buffer stays bounded.
            var offset = 0
            while offset < frameCount {
                let n = min(Self.scratchFrames, frameCount - offset)
                let chunk = output.advanced(by: offset * 2)

                if rtFading {
                    memcpy(scratch, chunk, n * 2 * MemoryLayout<Float>.size)
                    runPath(rtOldSetup, gain: rtOldGain, bankIndex: rtOldBank, buf: scratch, frames: n)
                    runPath(rtCurSetup, gain: rtCurGain, bankIndex: rtCurBank, buf: chunk, frames: n)

                    // chunk = old + (new - old) * t, t ramps 0 → 1
                    let len = Float(rtFadeLen)
                    for i in 0..<n {
                        let pos = rtFadePos + i
                        let t: Float = pos >= rtFadeLen ? 1.0 : Float(pos) / len
                        let l = i * 2
                        let oldL = scratch[l], oldR = scratch[l + 1]
                        chunk[l] = oldL + (chunk[l] - oldL) * t
                        chunk[l + 1] = oldR + (chunk[l + 1] - oldR) * t
                    }
                    rtFadePos += n
                    if rtFadePos >= rtFadeLen {
                        rtFading = false
                        rtOldSetup = nil
                        _rtActive.store(rtCurSetup != nil, ordering: .relaxed)
                        _rtAckSeq.store(rtSeenSeq, ordering: .releasing)
                    }
                } else {
                    runPath(rtCurSetup, gain: rtCurGain, bankIndex: rtCurBank, buf: chunk, frames: n)
                }
                offset += n
            }
        }

        // Non-finite safety net — pathological coefficients can produce NaN/Inf anywhere
        // in the block that would propagate through the entire downstream chain.
        let sampleCount = frameCount * 2
        var hasNonFinite = false
        for i in 0..<sampleCount {
            if !output[i].isFinite {
                hasNonFinite = true
                break
            }
        }
        if hasNonFinite {
            clearBank(0); clearBank(1)
            memset(output, 0, sampleCount * MemoryLayout<Float>.size)
        }
    }
}
