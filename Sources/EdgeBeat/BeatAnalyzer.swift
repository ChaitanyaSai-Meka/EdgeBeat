import Accelerate
import Foundation

struct AudioFeatures {
    var level: Double
    var bass: Double
    var mid: Double
    var treble: Double
    var beat: Bool
    var waveform: [Double]

    static let silence = AudioFeatures(level: 0, bass: 0, mid: 0, treble: 0, beat: false, waveform: [])
}

final class BeatAnalyzer {
    var onFeatures: ((AudioFeatures) -> Void)?

    private let analysisQueue = DispatchQueue(label: "com.chaitanya.edgebeat.analysis", qos: .utility)
    private let fftSize = 2048
    private let log2Size: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var pendingSamples: [Float] = []
    private var smoothedLevel = 0.0
    private var bassHistory: [Double] = []
    private var lastBeatTime = 0.0
    private var lastAnalysisTime = 0.0
    private var minimumAnalysisInterval = 1.0 / 20.0
    private var previousWaveform = [Double](repeating: 0, count: 128)

    init?() {
        log2Size = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        pendingSamples.reserveCapacity(fftSize * 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func consume(samples: [Float], sampleRate: Double) {
        analysisQueue.async { [weak self] in
            self?.consumeOnAnalysisQueue(samples: samples, sampleRate: sampleRate)
        }
    }

    func setLowPowerMode(_ enabled: Bool) {
        analysisQueue.async { [weak self] in
            self?.minimumAnalysisInterval = 1.0 / (enabled ? 15.0 : 20.0)
        }
    }

    private func consumeOnAnalysisQueue(samples: [Float], sampleRate: Double) {
        pendingSamples.append(contentsOf: samples)
        let maximumBufferedSamples = fftSize * 2
        if pendingSamples.count > maximumBufferedSamples {
            pendingSamples.removeFirst(pendingSamples.count - maximumBufferedSamples)
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard pendingSamples.count >= fftSize,
              now - lastAnalysisTime >= minimumAnalysisInterval else { return }

        let frame = Array(pendingSamples.suffix(fftSize))
        pendingSamples.removeAll(keepingCapacity: true)
        lastAnalysisTime = now
        analyze(frame, sampleRate: sampleRate, now: now)
    }

    private func analyze(_ samples: [Float], sampleRate: Double, now: TimeInterval) {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var rms: Float = 0
        vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(fftSize))
        let normalizedLevel = min(1, max(0, Double(rms) * 7.5))
        let coefficient = normalizedLevel > smoothedLevel ? 0.48 : 0.14
        smoothedLevel += (normalizedLevel - smoothedLevel) * coefficient

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        windowed.withUnsafeBufferPointer { input in
            input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexInput in
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                        var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                        vDSP_ctoz(complexInput, 2, &split, 1, vDSP_Length(fftSize / 2))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                    }
                }
            }
        }

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        let bass = bandEnergy(magnitudes, from: 45, to: 180, sampleRate: sampleRate)
        let mid = bandEnergy(magnitudes, from: 180, to: 2_000, sampleRate: sampleRate)
        let treble = bandEnergy(magnitudes, from: 2_000, to: 10_000, sampleRate: sampleRate)
        bassHistory.append(bass)
        if bassHistory.count > 32 { bassHistory.removeFirst() }
        let baseline = bassHistory.isEmpty ? 0 : bassHistory.reduce(0, +) / Double(bassHistory.count)
        let isBeat = bass > baseline * 1.5 && bass > 0.012 && now - lastBeatTime > 0.22
        if isBeat { lastBeatTime = now }

        let features = AudioFeatures(
            level: smoothedLevel,
            bass: normalizeBand(bass),
            mid: normalizeBand(mid),
            treble: normalizeBand(treble),
            beat: isBeat,
            waveform: makeWaveform(from: samples)
        )
        DispatchQueue.main.async { [weak self] in self?.onFeatures?(features) }
    }

    private func bandEnergy(_ magnitudes: [Float], from lowHz: Double, to highHz: Double,
                            sampleRate: Double) -> Double {
        let binWidth = sampleRate / Double(fftSize)
        let lower = max(1, Int(lowHz / binWidth))
        let upper = min(magnitudes.count - 1, Int(highHz / binWidth))
        guard lower <= upper else { return 0 }
        let values = magnitudes[lower...upper]
        return values.reduce(0) { $0 + Double($1) } / Double(values.count)
    }

    private func normalizeBand(_ value: Double) -> Double {
        min(1, max(0, sqrt(value) * 0.18))
    }

    private func makeWaveform(from samples: [Float]) -> [Double] {
        let pointCount = previousWaveform.count
        let binSize = max(1, samples.count / pointCount)
        var waveform = [Double](repeating: 0, count: pointCount)

        for point in 0..<pointCount {
            let start = point * binSize
            let end = min(samples.count, start + binSize)
            guard start < end else { continue }
            var energy = 0.0
            for index in start..<end {
                let sample = Double(samples[index])
                energy += sample * sample
            }
            waveform[point] = sqrt(energy / Double(end - start))
        }

        let peak = waveform.max() ?? 0
        if peak > 0.0001 {
            for index in waveform.indices { waveform[index] /= peak }
        }

        if waveform.count > 2 {
            var spatiallySmoothed = waveform
            for index in 1..<(waveform.count - 1) {
                spatiallySmoothed[index] = (waveform[index - 1] + waveform[index] * 2 + waveform[index + 1]) / 4
            }
            waveform = spatiallySmoothed
        }

        for index in waveform.indices {
            waveform[index] = previousWaveform[index] * 0.58 + waveform[index] * 0.42
        }
        previousWaveform = waveform
        return waveform
    }
}
