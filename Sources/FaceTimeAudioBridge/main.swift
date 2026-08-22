import AppKit
import CoreAudio
import AudioToolbox
import ServiceManagement
import os.lock

struct AudioDevice: Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: UInt32
    let outputChannels: UInt32
    let sampleRate: Double
}

enum BridgeError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)
    case sampleRateMismatch(Double, Double)
    case noDevice

    var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            return "\(operation) failed (Core Audio error \(status))."
        case let .unsupportedFormat(message): return message
        case let .sampleRateMismatch(source, destination):
            return "Sample rates do not match (source: \(Int(source)) Hz, destination: \(Int(destination)) Hz). Set both devices to the same rate in Audio MIDI Setup."
        case .noDevice: return "The selected audio device is no longer available."
        }
    }
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw BridgeError.coreAudio(operation, status) }
}

enum AudioDevices {
    static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func device(_ id: AudioDeviceID) -> AudioDevice? {
        guard let name = string(id, kAudioObjectPropertyName),
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(
            id: id,
            name: name,
            uid: uid,
            inputChannels: channels(id, kAudioDevicePropertyScopeInput),
            outputChannels: channels(id, kAudioDevicePropertyScopeOutput),
            sampleRate: sampleRate(id)
        )
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func sampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }

    static func streamFormat(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &format), "Read device format")
        return format
    }

    static func bufferFrameSize(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 512
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames)
        return frames
    }
}

final class StereoRingBuffer: @unchecked Sendable {
    private var samples: [Float]
    private var readFrame = 0
    private var writeFrame = 0
    private var availableFrames = 0
    private var lock = os_unfair_lock_s()
    let capacityFrames: Int
    private var targetLatencyFrames: Int
    private var maximumLatencyFrames: Int

    init(capacityFrames: Int, targetLatencyFrames: Int = 512, maximumLatencyFrames: Int = 1_536) {
        self.capacityFrames = capacityFrames
        self.targetLatencyFrames = targetLatencyFrames
        self.maximumLatencyFrames = maximumLatencyFrames
        samples = [Float](repeating: 0, count: capacityFrames * 2)
    }

    func configure(framesPerBuffer: Int) {
        let quantum = max(128, framesPerBuffer)
        targetLatencyFrames = min(capacityFrames / 2, quantum * 2)
        maximumLatencyFrames = min(capacityFrames - 1, quantum * 4)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        readFrame = 0; writeFrame = 0; availableFrames = 0
        os_unfair_lock_unlock(&lock)
    }

    func write(_ list: UnsafePointer<AudioBufferList>, frames: Int) {
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard !buffers.isEmpty else { return }
        let count = min(frames, capacityFrames)
        let interleaved = buffers.count == 1 && buffers[0].mNumberChannels >= 2
        guard let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let rightData = (!interleaved && buffers.count > 1) ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        for frame in 0..<count {
            let destination = ((writeFrame + frame) % capacityFrames) * 2
            samples[destination] = interleaved ? leftData[frame * Int(buffers[0].mNumberChannels)] : leftData[frame]
            samples[destination + 1] = interleaved ? leftData[frame * Int(buffers[0].mNumberChannels) + 1] : (rightData?[frame] ?? samples[destination])
        }
        if count > capacityFrames - availableFrames {
            let overwritten = count - (capacityFrames - availableFrames)
            readFrame = (readFrame + overwritten) % capacityFrames
        }
        writeFrame = (writeFrame + count) % capacityFrames
        availableFrames = min(capacityFrames, availableFrames + count)
    }

    func read(into list: UnsafeMutablePointer<AudioBufferList>, frames: Int, gain: Float) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for index in buffers.indices {
            if let data = buffers[index].mData { memset(data, 0, Int(buffers[index].mDataByteSize)) }
        }
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }
        guard !buffers.isEmpty else { return }
        // The virtual source and physical destination use separate hardware clocks.
        // If the source runs even slightly faster, latency otherwise grows forever.
        // Drop only stale queued audio, retaining a small cushion for stable playback.
        if availableFrames > maximumLatencyFrames {
            let staleFrames = availableFrames - targetLatencyFrames
            readFrame = (readFrame + staleFrames) % capacityFrames
            availableFrames -= staleFrames
        }
        let count = min(frames, availableFrames)
        let interleaved = buffers.count == 1 && buffers[0].mNumberChannels >= 2
        guard let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let rightData = (!interleaved && buffers.count > 1) ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        for frame in 0..<count {
            let source = ((readFrame + frame) % capacityFrames) * 2
            if interleaved {
                let channels = Int(buffers[0].mNumberChannels)
                leftData[frame * channels] = samples[source] * gain
                leftData[frame * channels + 1] = samples[source + 1] * gain
            } else {
                leftData[frame] = samples[source] * gain
                rightData?[frame] = samples[source + 1] * gain
            }
        }
        readFrame = (readFrame + count) % capacityFrames
        availableFrames -= count
    }
}

final class AudioBridge: @unchecked Sendable {
    // Keep enough storage for safety, but actively bound playback latency to roughly
    // 10–32 ms at 48 kHz in StereoRingBuffer.read().
    private let ring = StereoRingBuffer(capacityFrames: 24_000)
    private var inputProc: AudioDeviceIOProcID?
    private var outputProc: AudioDeviceIOProcID?
    private var sourceID: AudioDeviceID = 0
    private var destinationID: AudioDeviceID = 0
    private(set) var isRunning = false
    var outputGain: Float = 1

    func start(source: AudioDevice, destination: AudioDevice) throws {
        stop()
        guard source.inputChannels >= 2, destination.outputChannels >= 2 else {
            throw BridgeError.unsupportedFormat("Both devices must provide at least two channels.")
        }
        guard abs(source.sampleRate - destination.sampleRate) < 1 else {
            throw BridgeError.sampleRateMismatch(source.sampleRate, destination.sampleRate)
        }
        let inputFormat = try AudioDevices.streamFormat(source.id, scope: kAudioDevicePropertyScopeInput)
        let outputFormat = try AudioDevices.streamFormat(destination.id, scope: kAudioDevicePropertyScopeOutput)
        let requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        guard inputFormat.mFormatID == kAudioFormatLinearPCM,
              outputFormat.mFormatID == kAudioFormatLinearPCM,
              inputFormat.mBitsPerChannel == 32, outputFormat.mBitsPerChannel == 32,
              inputFormat.mFormatFlags & requiredFlags == requiredFlags,
              outputFormat.mFormatFlags & requiredFlags == requiredFlags else {
            throw BridgeError.unsupportedFormat("The selected devices must use 32-bit floating-point PCM. Check their format in Audio MIDI Setup.")
        }
        sourceID = source.id; destinationID = destination.id; ring.reset()
        let sourceBuffer = Int(AudioDevices.bufferFrameSize(source.id))
        let destinationBuffer = Int(AudioDevices.bufferFrameSize(destination.id))
        ring.configure(framesPerBuffer: max(sourceBuffer, destinationBuffer))
        let context = Unmanaged.passUnretained(self).toOpaque()
        try check(AudioDeviceCreateIOProcID(sourceID, { _, _, input, _, _, _, context in
            guard let context else { return noErr }
            let bridge = Unmanaged<AudioBridge>.fromOpaque(context).takeUnretainedValue()
            let frames = Int(input.pointee.mBuffers.mDataByteSize) / max(1, Int(bridge.inputBytesPerFrame(input)))
            bridge.ring.write(input, frames: frames)
            return noErr
        }, context, &inputProc), "Create source callback")
        try check(AudioDeviceCreateIOProcID(destinationID, { _, _, _, _, output, _, context in
            guard let context else { return noErr }
            let bridge = Unmanaged<AudioBridge>.fromOpaque(context).takeUnretainedValue()
            let frames = Int(output.pointee.mBuffers.mDataByteSize) / max(1, Int(bridge.outputBytesPerFrame(output)))
            bridge.ring.read(into: output, frames: frames, gain: bridge.outputGain)
            return noErr
        }, context, &outputProc), "Create destination callback")
        if let outputProc { try check(AudioDeviceStart(destinationID, outputProc), "Start destination") }
        if let inputProc { try check(AudioDeviceStart(sourceID, inputProc), "Start source") }
        isRunning = true
    }

    private func inputBytesPerFrame(_ list: UnsafePointer<AudioBufferList>) -> UInt32 {
        let buffer = list.pointee.mBuffers
        return max(4, 4 * buffer.mNumberChannels)
    }
    private func outputBytesPerFrame(_ list: UnsafePointer<AudioBufferList>) -> UInt32 {
        let buffer = list.pointee.mBuffers
        return max(4, 4 * buffer.mNumberChannels)
    }

    func stop() {
        if let inputProc { _ = AudioDeviceStop(sourceID, inputProc); _ = AudioDeviceDestroyIOProcID(sourceID, inputProc) }
        if let outputProc { _ = AudioDeviceStop(destinationID, outputProc); _ = AudioDeviceDestroyIOProcID(destinationID, outputProc) }
        inputProc = nil; outputProc = nil; isRunning = false; ring.reset()
    }

    deinit { stop() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let boostLevels: [(title: String, decibels: Float)] = [
        ("0 dB", 0), ("+6 dB", 6), ("+12 dB", 12), ("+18 dB", 18), ("+24 dB", 24)
    ]
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let bridge = AudioBridge()
    private var devices: [AudioDevice] = []
    private var selectedSource: AudioDevice?
    private var selectedDestination: AudioDevice?
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.title = "⇄"
        statusItem.button?.toolTip = "FaceTime Audio Bridge"
        let savedBoost = defaults.object(forKey: "boostDecibels") == nil ? 12 : defaults.float(forKey: "boostDecibels")
        setBoost(decibels: savedBoost)
        refreshDevices()
        if defaults.bool(forKey: "startOnLogin") {
            // Give Core Audio a moment to finish discovering USB and virtual devices at login.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startBridge(showErrors: true)
            }
        }
    }

    private func refreshDevices() {
        devices = AudioDevices.all()
        let inputDevices = devices.filter { $0.inputChannels >= 2 }
        let outputDevices = devices.filter { $0.outputChannels >= 2 }
        let sourceUID = defaults.string(forKey: "sourceUID")
        let destinationUID = defaults.string(forKey: "destinationUID")
        selectedSource = inputDevices.first { $0.uid == sourceUID }
            ?? inputDevices.first { $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") }
            ?? inputDevices.first { $0.name.localizedCaseInsensitiveContains("BlackHole") }
        selectedDestination = outputDevices.first { $0.uid == destinationUID }
            ?? outputDevices.first { !$0.name.localizedCaseInsensitiveContains("BlackHole") }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: bridge.isRunning ? "● Bridging audio" : "○ Bridge stopped", action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(submenu(title: "Source (FaceTime output)", devices: devices.filter { $0.inputChannels >= 2 }, selected: selectedSource, action: #selector(selectSource(_:))))
        menu.addItem(submenu(title: "Destination (headphones)", devices: devices.filter { $0.outputChannels >= 2 }, selected: selectedDestination, action: #selector(selectDestination(_:))))
        let boostParent = NSMenuItem(title: "FaceTime Boost", action: nil, keyEquivalent: "")
        let boostMenu = NSMenu(title: "FaceTime Boost")
        let currentBoost = defaults.object(forKey: "boostDecibels") == nil ? 12 : defaults.float(forKey: "boostDecibels")
        for level in boostLevels {
            let item = NSMenuItem(title: level.title, action: #selector(selectBoost(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: level.decibels)
            item.state = abs(level.decibels - currentBoost) < 0.1 ? .on : .off
            boostMenu.addItem(item)
        }
        boostParent.submenu = boostMenu
        menu.addItem(boostParent)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: bridge.isRunning ? "Stop Bridge" : "Start Bridge", action: #selector(toggleBridge), keyEquivalent: "b")
        toggle.target = self; menu.addItem(toggle)
        let refresh = NSMenuItem(title: "Refresh Audio Devices", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self; menu.addItem(refresh)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start on Login", action: #selector(toggleStartOnLogin), keyEquivalent: "")
        login.target = self
        login.state = defaults.bool(forKey: "startOnLogin") ? .on : .off
        menu.addItem(login)
        let setup = NSMenuItem(title: "Setup Instructions…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self; menu.addItem(setup)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.title = bridge.isRunning ? "⇄●" : "⇄"
    }

    private func submenu(title: String, devices: [AudioDevice], selected: AudioDevice?, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu(title: title)
        if devices.isEmpty {
            let none = NSMenuItem(title: "No compatible devices", action: nil, keyEquivalent: ""); none.isEnabled = false; child.addItem(none)
        }
        for device in devices {
            let item = NSMenuItem(title: "\(device.name) — \(Int(device.sampleRate)) Hz", action: action, keyEquivalent: "")
            item.target = self; item.representedObject = device.uid; item.state = device.uid == selected?.uid ? .on : .off
            child.addItem(item)
        }
        parent.submenu = child
        return parent
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard !bridge.isRunning, let uid = sender.representedObject as? String else { showStopFirst(); return }
        selectedSource = devices.first { $0.uid == uid }; defaults.set(uid, forKey: "sourceUID"); rebuildMenu()
    }
    @objc private func selectDestination(_ sender: NSMenuItem) {
        guard !bridge.isRunning, let uid = sender.representedObject as? String else { showStopFirst(); return }
        selectedDestination = devices.first { $0.uid == uid }; defaults.set(uid, forKey: "destinationUID"); rebuildMenu()
    }
    @objc private func selectBoost(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        let decibels = value.floatValue
        defaults.set(decibels, forKey: "boostDecibels")
        setBoost(decibels: decibels)
        rebuildMenu()
    }
    private func setBoost(decibels: Float) {
        bridge.outputGain = powf(10, decibels / 20)
    }
    @objc private func refresh() { if !bridge.isRunning { refreshDevices() } else { showStopFirst() } }
    @objc private func toggleBridge() {
        if bridge.isRunning { bridge.stop(); rebuildMenu(); return }
        startBridge(showErrors: true)
    }
    private func startBridge(showErrors: Bool) {
        guard !bridge.isRunning else { return }
        guard let source = selectedSource, let destination = selectedDestination else { showError(BridgeError.noDevice); return }
        do { try bridge.start(source: source, destination: destination); rebuildMenu() }
        catch {
            bridge.stop(); rebuildMenu()
            if showErrors { showError(error) }
        }
    }
    @objc private func toggleStartOnLogin() {
        let enable = !defaults.bool(forKey: "startOnLogin")
        do {
            if enable {
                try SMAppService.mainApp.register()
                defaults.set(true, forKey: "startOnLogin")
                startBridge(showErrors: true)
            } else {
                try SMAppService.mainApp.unregister()
                defaults.set(false, forKey: "startOnLogin")
            }
            rebuildMenu()
        } catch {
            showMessage("macOS could not update the Login Items setting. \(error.localizedDescription)\n\nYou can review permission under System Settings → General → Login Items.")
        }
    }
    private func showStopFirst() { showMessage("Stop the bridge before changing or refreshing audio devices.") }
    private func showError(_ error: Error) { showMessage(error.localizedDescription) }
    private func showMessage(_ text: String) {
        let alert = NSAlert(); alert.messageText = "FaceTime Audio Bridge"; alert.informativeText = text; alert.runModal()
    }
    @objc private func showSetup() {
        showMessage("1. In macOS Sound settings, keep your normal output routing unchanged.\n\n2. In FaceTime’s Video menu, choose a BlackHole device reserved for FaceTime as Output and your XLR interface as Microphone.\n\n3. Here, choose that same BlackHole device as Source and your interface as Destination, then Start Bridge.\n\nUse FaceTime Boost to raise only the call without changing Mac volume. Start on Login launches the app and starts the saved bridge automatically.\n\nIf BlackHole 2ch already feeds OBS, use a separate BlackHole device for FaceTime. Avoid routing the bridge into FaceTime’s microphone, which would create echo.")
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
