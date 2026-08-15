import CoreAudio
import Foundation
import OSLog

final class AudioTapEngine {
    enum TapError: LocalizedError {
        case unsupported
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupported: "Audio capture requires macOS 14.4 or newer."
            case let .coreAudio(operation, status): "\(operation) failed (OSStatus \(status))."
            }
        }
    }

    var onSamples: (([Float], Double) -> Void)?
    var onStatusChange: ((String?) -> Void)?

    private let logger = Logger(subsystem: "com.chaitanya.edgebeat", category: "audio")
    private let controlQueue = DispatchQueue(label: "com.chaitanya.edgebeat.audio-control", qos: .utility)
    private let ioQueue = DispatchQueue(label: "com.chaitanya.edgebeat.audio-io", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private var activeProcessID: pid_t?
    private var hasReceivedSamples = false
    private var hasReportedEmptyBuffer = false
    private var pendingSamples: [Float] = []
    private let sampleDeliverySize = 2048

    func start(processID: pid_t?) {
        controlQueue.async { [weak self] in
            self?.startOnControlQueue(processID: processID)
        }
    }

    private func startOnControlQueue(processID: pid_t?) {
        let processDescription = processID.map(String.init) ?? "global"
        logger.info("Starting audio tap for process \(processDescription, privacy: .public)")
        guard activeProcessID != processID || tapID == kAudioObjectUnknown else { return }
        stopOnControlQueue()
        do {
            try createTap(processID: processID)
            activeProcessID = processID
            logger.notice("Audio tap started")
            onStatusChange?("Audio capture active - waiting for sound...")
        } catch {
            logger.error("Player-specific audio tap failed: \(error.localizedDescription, privacy: .public)")
            if processID != nil {
                do {
                    try createTap(processID: nil)
                    activeProcessID = nil
                    logger.notice("Global audio fallback started")
                    onStatusChange?("System-wide audio capture active - waiting for sound...")
                    return
                } catch {
                    stopOnControlQueue()
                }
            }
            onStatusChange?(error.localizedDescription)
            logger.error("Global audio tap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        controlQueue.async { [weak self] in
            self?.stopOnControlQueue()
        }
    }

    private func stopOnControlQueue() {
        logger.info("Stopping audio tap")
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        aggregateDeviceID = kAudioObjectUnknown
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        }
        tapID = kAudioObjectUnknown
        activeProcessID = nil
        hasReceivedSamples = false
        hasReportedEmptyBuffer = false
        pendingSamples.removeAll(keepingCapacity: true)
    }

    private func createTap(processID: pid_t?) throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupported }
        let description: CATapDescription
        if let processID, let objectID = processObjectID(for: processID) {
            description = CATapDescription(stereoMixdownOfProcesses: [objectID])
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.name = "EdgeBeat Audio Tap"
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")
        format = try audioFormat(for: tapID)
        logger.notice("Tap format: \(self.format.mSampleRate) Hz, \(self.format.mChannelsPerFrame) channels, \(self.format.mBitsPerChannel) bits, flags \(self.format.mFormatFlags)")

        let aggregateUID = "com.chaitanya.edgebeat.aggregate.\(UUID().uuidString)"
        let dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EdgeBeat Audio Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregateDeviceID),
                  "Create aggregate device")

        let sampleRate = format.mSampleRate
        var createdIOProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&createdIOProc, aggregateDeviceID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            let samples = self.copyMonoSamples(from: inputData)
            if samples.isEmpty {
                if !self.hasReportedEmptyBuffer {
                    self.hasReportedEmptyBuffer = true
                    self.logger.error("Audio callback arrived without readable Float32 samples")
                    self.onStatusChange?("Audio callback received an unsupported or empty buffer.")
                }
                return
            }
            if !self.hasReceivedSamples {
                self.hasReceivedSamples = true
                self.logger.notice("Receiving audio samples")
                self.onStatusChange?("Audio capture active")
            }
            self.pendingSamples.append(contentsOf: samples)
            guard self.pendingSamples.count >= self.sampleDeliverySize else { return }
            var batch: [Float] = []
            swap(&batch, &self.pendingSamples)
            self.pendingSamples.reserveCapacity(self.sampleDeliverySize)
            self.onSamples?(batch, sampleRate)
        }
        try check(status, "Create audio IO callback")
        ioProcID = createdIOProc
        try check(AudioDeviceStart(aggregateDeviceID, createdIOProc), "Start audio capture")
    }

    private func processObjectID(for processID: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = processID
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), qualifier, &size, &objectID
            )
        }
        return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
    }

    private func audioFormat(for objectID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "Read audio format")
        return value
    }

    private func copyMonoSamples(from inputData: UnsafePointer<AudioBufferList>) -> [Float] {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !buffers.isEmpty else { return [] }
        let channels = max(1, Int(format.mChannelsPerFrame))

        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            let frameCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            var mono = [Float](repeating: 0, count: frameCount)
            var usedChannels = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let values = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount { mono[frame] += values[frame] }
                usedChannels += 1
            }
            guard usedChannels > 0 else { return [] }
            let divisor = Float(usedChannels)
            for index in mono.indices { mono[index] /= divisor }
            return mono
        }

        guard let data = buffers[0].mData else { return [] }
        let sampleCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let frameCount = sampleCount / channels
        let values = data.assumingMemoryBound(to: Float.self)
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var value: Float = 0
            for channel in 0..<channels { value += values[frame * channels + channel] }
            mono[frame] = value / Float(channels)
        }
        return mono
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            logger.error("\(operation, privacy: .public) returned OSStatus \(status)")
            throw TapError.coreAudio(operation, status)
        }
    }
}
