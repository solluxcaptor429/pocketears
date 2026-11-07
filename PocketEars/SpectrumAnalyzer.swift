import Accelerate
import Foundation

/// Mic samples -> the sign's LSV2 payload: 16 spectrum bytes + 64 oscilloscope bytes.
///
/// Band shaping follows BuddyEars `dsp.c` so the sign sees the same kind of signal it
/// gets from the 3DS: each band is its peak bin blended 75/25 with its RMS, bands
/// narrower than a bin are interpolated, a treble tilt lifts the upper bands, and the
/// result is mapped linearly in dB from the noise floor (0) to full scale (255).
/// No smoothing here -- the sign does its own attack/release.
final class SpectrumAnalyzer {
    static let fftSize = 4096
    static let bandCount = 16
    static let waveCount = 64
    static let lowHz: Float = 45

    struct Settings {
        var floorDB: Float = -60
        var tiltDBPerOctave: Float = 3
        var gainDB: Float = 0
        var autoGain = true
    }

    struct Output {
        var bands = [UInt8](repeating: 0, count: SpectrumAnalyzer.bandCount)
        var wave = [UInt8](repeating: 128, count: SpectrumAnalyzer.waveCount)
        var levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        var appliedGainDB: Float = 0
    }

    let sampleRate: Float
    private let n = SpectrumAnalyzer.fftSize
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var centered: [Float]
    private var windowed: [Float]
    private var re: [Float]
    private var im: [Float]
    private var mag: [Float]
    private var binLo = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var binHi = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var centerHz = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var tilt = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var tiltSetting: Float = -1
    private var envelopeDB: Float = -30
    private let waveSpan: Int

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        log2n = vDSP_Length(log2(Float(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        centered = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        re = [Float](repeating: 0, count: n / 2)
        im = [Float](repeating: 0, count: n / 2)
        mag = [Float](repeating: 0, count: n / 2)
        // ~10.7 ms of audio for the oscilloscope, same as the Windows feeder.
        waveSpan = max(Self.waveCount, Int(self.sampleRate * 0.0107))

        let high = min(16_000, self.sampleRate * 0.45)
        let binHz = self.sampleRate / Float(n)
        let maxBin = Float(n / 2) - 2
        for i in 0..<Self.bandCount {
            let f0 = Self.lowHz * pow(high / Self.lowHz, Float(i) / Float(Self.bandCount))
            let f1 = Self.lowHz * pow(high / Self.lowHz, Float(i + 1) / Float(Self.bandCount))
            var b0 = max(f0 / binHz, 1)
            var b1 = min(f1 / binHz, maxBin)
            if b1 < b0 { b1 = b0 }
            if b0 > maxBin { b0 = maxBin }
            binLo[i] = b0
            binHi[i] = b1
            centerHz[i] = (f0 * f1).squareRoot()
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    private func updateTilt(_ perOctave: Float) {
        guard perOctave != tiltSetting else { return }
        tiltSetting = perOctave
        for i in 0..<Self.bandCount {
            tilt[i] = perOctave * log2(centerHz[i] / Self.lowHz)
        }
    }

    /// `frame` holds the latest `fftSize` mono samples, -1...1.
    func process(_ frame: [Float], settings s: Settings) -> Output {
        var out = Output()
        let count = vDSP_Length(n)
        updateTilt(s.tiltDBPerOctave)

        var mean: Float = 0
        vDSP_meanv(frame, 1, &mean, count)
        var negMean = -mean
        vDSP_vsadd(frame, 1, &negMean, &centered, 1, count)
        vDSP_vmul(centered, 1, window, 1, &windowed, 1, count)

        let half = n / 2
        let l2 = log2n
        let fft = setup
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let cp = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(cp.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fft, &split, 1, l2, FFTDirection(kFFTDirection_Forward))
                split.realp[0] = 0   // DC
                split.imagp[0] = 0   // packed Nyquist
                mag.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // vDSP's real FFT is scaled by 2, and a full-scale sine under a Hann window
        // peaks at N/4 in a true DFT: N/2 here is the 0 dBFS reference.
        let refMag = Float(n) / 2
        var rawDB = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let i0 = Int(binLo[b].rounded(.up))
            let i1 = Int(binHi[b].rounded(.down))
            var m: Float
            if i1 - i0 < 1 {
                let c = 0.5 * (binLo[b] + binHi[b])
                var ci = Int(c)
                var frac = c - Float(ci)
                if ci < 1 { ci = 1; frac = 0 }
                if ci > half - 2 { ci = half - 2; frac = 0 }
                m = mag[ci] * (1 - frac) + mag[ci + 1] * frac
            } else {
                var mx: Float = 0
                var acc: Float = 0
                for i in i0...i1 {
                    let v = mag[i]
                    if v > mx { mx = v }
                    acc += v * v
                }
                m = 0.75 * mx + 0.25 * (acc / Float(i1 - i0 + 1)).squareRoot()
            }
            rawDB[b] = 20 * log10(m / refMag + 1e-9) + tilt[b]
        }

        // Auto gain: a phone across the room hears far less than a line feed. Track
        // the loudest band (fast up, ~2 dB/s down) and lift it toward the top of the
        // bars, capped so a quiet room doesn't turn into a wall of noise.
        var auto: Float = 0
        if s.autoGain {
            let loudest = rawDB.max() ?? -90
            if loudest > envelopeDB {
                envelopeDB += (loudest - envelopeDB) * 0.5
            } else {
                envelopeDB = max(envelopeDB - 0.03, -60)
            }
            let target = s.floorDB * 0.12
            auto = min(max(target - envelopeDB, 0), 18)
        }
        let gain = auto + s.gainDB
        out.appliedGainDB = gain

        let span = -s.floorDB
        for b in 0..<Self.bandCount {
            let v = min(max((rawDB[b] + gain - s.floorDB) / span, 0), 1)
            out.levels[b] = v
            out.bands[b] = UInt8(v * 255 + 0.5)
        }

        // Oscilloscope: latest ~11 ms, DC removed, resampled to 64, DC at 128.
        let lin = pow(10, gain / 20)
        let start = n - waveSpan
        for i in 0..<Self.waveCount {
            let pos = Float(i) * Float(waveSpan - 1) / Float(Self.waveCount - 1)
            let lo = Int(pos)
            let hi = min(lo + 1, waveSpan - 1)
            let frac = pos - Float(lo)
            let v = (centered[start + lo] * (1 - frac) + centered[start + hi] * frac) * lin
            let clamped = min(max(v, -1), 1)
            out.wave[i] = UInt8((clamped + 1) * 127.5 + 0.5)
        }
        return out
    }
}
