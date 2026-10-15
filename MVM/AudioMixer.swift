import Foundation
import CoreAudio
import AVFoundation
import AudioToolbox
import AppKit
import Combine
import os

// MARK: - TapAudioSession

/// Holds Core Audio and AVFoundation resources for a single tapped application.
private final class TapAudioSession {
    let pid: pid_t
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    var ioProcID: AudioDeviceIOProcID?
    let playerNode: AVAudioPlayerNode
    let standardFormat: AVAudioFormat

    // Fixed pool of pre-allocated buffers to prevent heap allocations in the real-time audio thread
    private let poolSize = 32
    private var bufferPool: [AVAudioPCMBuffer] = []
    private var poolIndex: Int = 0

    // Lock-free timestamp for audio activity detection (UI green indicator)
    private var _lastAudioActivityMachTime: UInt64 = 0
    private var lock = os_unfair_lock()

    var volume: Float = 1.0
    var isMuted: Bool = false

    var lastAudioActivityMachTime: UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _lastAudioActivityMachTime
    }

    func recordAudioActivity() {
        os_unfair_lock_lock(&lock)
        _lastAudioActivityMachTime = mach_absolute_time()
        os_unfair_lock_unlock(&lock)
    }

    init(
        pid: pid_t,
        tapID: AudioObjectID,
        aggregateDeviceID: AudioObjectID,
        playerNode: AVAudioPlayerNode,
        format: AVAudioFormat,
        volume: Float,
        isMuted: Bool
    ) {
        self.pid = pid
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
        self.playerNode = playerNode
        self.standardFormat = format
        self.volume = volume
        self.isMuted = isMuted

        // Pre-allocate buffer pool (2048 frames accommodates common Core Audio buffer sizes up to 48kHz)
        for _ in 0..<poolSize {
            if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) {
                bufferPool.append(buf)
            }
        }
    }

    /// Provides a preallocated PCM buffer cycling through the pool.
    func nextBuffer(frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard !bufferPool.isEmpty else { return nil }
        let buf = bufferPool[poolIndex]
        poolIndex = (poolIndex + 1) % bufferPool.count
        buf.frameLength = min(frameCount, buf.frameCapacity)
        return buf
    }
}

// MARK: - Real-time Core Audio I/O Procedure

/// C-convention callback invoked on the high-priority real-time audio thread.
/// Note: Must be non-blocking, allocation-free, and lock-free.
private func tapAudioIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData = inClientData else { return noErr }
    let session = Unmanaged<TapAudioSession>.fromOpaque(inClientData).takeUnretainedValue()

    let bufferList = inInputData.pointee
    guard bufferList.mNumberBuffers > 0 else { return noErr }
    let buffer = bufferList.mBuffers
    guard let dataPtr = buffer.mData else { return noErr }

    let byteSize = buffer.mDataByteSize
    let bytesPerFrame: UInt32 = 8 // Stereo Float32 interleaved: 2 channels * 4 bytes
    let frameCount = byteSize / bytesPerFrame
    guard frameCount > 0 else { return noErr }

    guard let pcmBuffer = session.nextBuffer(frameCount: frameCount) else {
        return noErr
    }

    guard let left = pcmBuffer.floatChannelData?[0],
          let right = pcmBuffer.floatChannelData?[1] else {
        return noErr
    }

    let floatPtr = dataPtr.assumingMemoryBound(to: Float.self)
    var hasAudioEnergy = false

    // Deinterleave stereo Float32 samples and check signal energy in a single pass
    for i in 0..<Int(frameCount) {
        let lSample = floatPtr[i * 2]
        let rSample = floatPtr[i * 2 + 1]
        left[i] = lSample
        right[i] = rSample

        if !hasAudioEnergy && (abs(lSample) > 0.001 || abs(rSample) > 0.001) {
            hasAudioEnergy = true
        }
    }

    if hasAudioEnergy {
        session.recordAudioActivity()
    }

    if session.playerNode.isPlaying {
        session.playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    return noErr
}

// MARK: - AudioMixer

/// Main audio mixer engine leveraging native Core Audio Process Taps (macOS 14.2+).
///
/// Features:
/// - Captures per-process audio streams using CATapDescription with .mutedWhenTapped.
/// - Prevents echo and duplicate audio: the tapped process is silenced at the hardware level,
///   and MVM's AVAudioEngine serves as the single authoritative output path.
/// - Zero external virtual audio driver required (no BlackHole needed).
/// - Dynamic discovery: watches `kAudioHardwarePropertyProcessObjectList` so applications
///   are automatically hooked as soon as they emit audio.
/// - Dynamic device migration: seamlessly routes audio to speakers/headphones on hardware route changes.
class AudioMixer: NSObject, ObservableObject {

    // MARK: - Published State

    /// Set of PIDs currently streaming audible sound (used for green activity indicators in UI).
    @Published var activeAudioPIDs: Set<pid_t> = []

    /// Set of PIDs that currently possess Core Audio objects / audio capabilities.
    @Published var audioCapablePIDs: Set<pid_t> = []

    // MARK: - Private State

    private let engine = AVAudioEngine()
    private let stateLock = NSLock()

    /// Active tap sessions mapped by target process ID.
    private var sessions: [pid_t: TapAudioSession] = [:]

    /// Retained opaque pointers passed to C callbacks.
    private var sessionPointers: [pid_t: UnsafeMutableRawPointer] = [:]

    /// PIDs that the user requested to capture, waiting for audio processes to be instantiated.
    private var pendingPIDs: Set<pid_t> = []

    /// User-configured volume per PID (persisted across tap re-creations).
    private var appVolumes: [pid_t: Float] = [:]

    /// User-configured mute state per PID.
    private var appMutes: [pid_t: Bool] = [:]

    /// Global master volume (0.0 ... 1.0).
    private var masterVolume: Float = 1.0

    /// Timer for polling audio activity timestamps without burdening the real-time thread.
    private var activityTimer: AnyCancellable?

    /// Mach time frequency info for activity threshold calculation.
    private var timebaseInfo = mach_timebase_info()

    // MARK: - Lifecycle

    override init() {
        super.init()
        mach_timebase_info(&timebaseInfo)
        checkPermissions()
        setupEngine()
        setupWorkspaceObservers()
        setupCoreAudioListeners()
        startActivityPolling()
        refreshAudioCapablePIDs()
    }

    deinit {
        activityTimer?.cancel()
        removeCoreAudioListeners()
        NotificationCenter.default.removeObserver(self)

        stateLock.lock()
        let activePids = Array(sessions.keys)
        stateLock.unlock()

        for pid in activePids {
            stopCapturingAudio(for: pid)
        }

        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Permissions

    func checkPermissions() {
        if CGPreflightScreenCaptureAccess() {
            print("✅ [AudioMixer] Screen capture / Audio tap permission granted.")
        } else {
            print("⚠️ [AudioMixer] Requesting screen capture permission for audio tap...")
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Engine Initialization

    private func setupEngine() {
        _ = engine.mainMixerNode
        engine.mainMixerNode.outputVolume = masterVolume

        do {
            try engine.start()
            print("🎵 [AudioMixer] AVAudioEngine started successfully.")
        } catch {
            print("❌ [AudioMixer] Failed to start AVAudioEngine: \(error)")
        }

        // Handle audio route/hardware configuration changes (e.g., plugging headphones)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        stateLock.lock()
        defer { stateLock.unlock() }

        print("🔄 [AudioMixer] Audio hardware route changed, restarting engine...")
        if !engine.isRunning {
            do {
                try engine.start()
                for session in sessions.values {
                    if !session.playerNode.isPlaying {
                        session.playerNode.play()
                    }
                }
                print("✅ [AudioMixer] Engine restarted successfully after route change.")
            } catch {
                print("❌ [AudioMixer] Engine restart failed: \(error)")
            }
        }
    }

    // MARK: - Workspace & Termination Observers

    private func setupWorkspaceObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTerminatedNotification(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func handleAppTerminatedNotification(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        stopCapturingAudio(for: pid)
        DispatchQueue.main.async {
            self.audioCapablePIDs.remove(pid)
        }
    }

    // MARK: - Core Audio Process Listener

    private func setupCoreAudioListeners() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            processListPropertyListener,
            selfPtr
        )
        if status != noErr {
            print("⚠️ [AudioMixer] Failed to add listener for ProcessObjectList: \(status)")
        }
    }

    private func removeCoreAudioListeners() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            processListPropertyListener,
            selfPtr
        )
    }

    fileprivate func handleProcessListChanged() {
        refreshAudioCapablePIDs()

        stateLock.lock()
        let pending = pendingPIDs
        stateLock.unlock()

        guard !pending.isEmpty else { return }

        // Attempt to create taps for any pending PIDs that newly initialized audio
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for pid in pending {
                self.attemptCreateTap(for: pid)
            }
        }
    }

    // MARK: - Public Controls

    /// Starts capturing audio for a target application PID.
    func startCapturingAudio(for pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        stateLock.lock()
        if sessions[pid] != nil {
            stateLock.unlock()
            return
        }
        pendingPIDs.insert(pid)
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.attemptCreateTap(for: pid)
        }
    }

    /// Stops capturing audio for a target application and cleans up all Core Audio resources.
    func stopCapturingAudio(for pid: pid_t) {
        stateLock.lock()
        pendingPIDs.remove(pid)
        guard let session = sessions.removeValue(forKey: pid) else {
            stateLock.unlock()
            return
        }
        let rawPtr = sessionPointers.removeValue(forKey: pid)
        stateLock.unlock()

        DispatchQueue.main.async {
            self.activeAudioPIDs.remove(pid)
        }

        // Stop IO procedure and destroy aggregate device
        if let procID = session.ioProcID {
            AudioDeviceStop(session.aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(session.aggregateDeviceID, procID)
        }
        AudioHardwareDestroyAggregateDevice(session.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(session.tapID)

        // Detach player node from AVAudioEngine
        session.playerNode.stop()
        engine.disconnectNodeOutput(session.playerNode)
        engine.detach(session.playerNode)

        // Release the retained session pointer
        if let rawPtr = rawPtr {
            Unmanaged<TapAudioSession>.fromOpaque(rawPtr).release()
        }

        print("🛑 [PID: \(pid)] Audio tap and aggregate device successfully torn down.")
    }

    /// Sets the volume (0.0 to 1.0) for a specific application.
    func setVolume(for pid: pid_t, volume: Double) {
        let vol = Float(max(0.0, min(1.0, volume)))
        stateLock.lock()
        appVolumes[pid] = vol
        let session = sessions[pid]
        let isMuted = appMutes[pid] ?? false
        stateLock.unlock()

        if let session = session {
            session.volume = vol
            session.playerNode.volume = isMuted ? 0.0 : vol
            print("🎚️ [PID: \(pid)] Volume updated: \(Int(vol * 100))%\(isMuted ? " (Muted)" : "")")
        }
    }

    /// Toggles the mute state for a specific application.
    func setMuted(for pid: pid_t, isMuted: Bool) {
        stateLock.lock()
        appMutes[pid] = isMuted
        let session = sessions[pid]
        let vol = appVolumes[pid] ?? 1.0
        stateLock.unlock()

        if let session = session {
            session.isMuted = isMuted
            session.playerNode.volume = isMuted ? 0.0 : vol
            print("🔇 [PID: \(pid)] Mute state: \(isMuted ? "ON" : "OFF")")
        }
    }

    /// Sets the master volume (0.0 to 1.0) affecting all mixed application streams.
    func setMasterVolume(_ volume: Double) {
        let clamped = Float(max(0.0, min(1.0, volume)))
        masterVolume = clamped
        engine.mainMixerNode.outputVolume = clamped
        print("🎛️ [AudioMixer] Master Volume: \(Int(clamped * 100))%")
    }

    /// Re-evaluates all running regular applications to identify which ones currently have audio objects.
    func refreshAudioCapablePIDs() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let runningApps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            var capable = Set<pid_t>()
            for app in runningApps {
                let objects = self.findAudioObjectIDs(for: app.processIdentifier)
                if !objects.isEmpty {
                    capable.insert(app.processIdentifier)
                }
            }
            DispatchQueue.main.async {
                if self.audioCapablePIDs != capable {
                    self.audioCapablePIDs = capable
                }
            }
        }
    }

    // MARK: - Tap Creation Pipeline

    private func attemptCreateTap(for pid: pid_t) {
        stateLock.lock()
        if sessions[pid] != nil {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let matchingObjectIDs = findAudioObjectIDs(for: pid)
        guard !matchingObjectIDs.isEmpty else {
            // App has not yet initialized audio or opened CoreAudio client; remains in pendingPIDs
            return
        }

        print("⏳ [PID: \(pid)] Found \(matchingObjectIDs.count) Core Audio process object(s): \(matchingObjectIDs). Creating tap...")

        // 1. Create CATapDescription with .mutedWhenTapped (silences process output at hardware level)
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: matchingObjectIDs)
        tapDesc.name = "MVM-Tap-\(pid)"
        tapDesc.muteBehavior = .mutedWhenTapped
        tapDesc.isPrivate = true

        // 2. Register process tap with Core Audio
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            print("❌ [PID: \(pid)] AudioHardwareCreateProcessTap failed with OSStatus \(tapStatus)")
            return
        }

        // 3. Retrieve tap UID
        guard let tapUID = getTapUID(for: tapID) else {
            print("❌ [PID: \(pid)] Failed to retrieve tap UID. Destroying tap.")
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        // 4. Create a private Aggregate Device wrapping the tap as its input sub-device
        guard let aggregateDeviceID = createAggregateDevice(tapUID: tapUID, for: pid) else {
            print("❌ [PID: \(pid)] Failed to create aggregate device. Destroying tap.")
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        // 5. Connect to AVAudioEngine on Main Thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                AudioHardwareDestroyProcessTap(tapID)
                return
            }

            self.wireEngineAndStartIO(
                pid: pid,
                tapID: tapID,
                aggregateDeviceID: aggregateDeviceID
            )
        }
    }

    private func wireEngineAndStartIO(
        pid: pid_t,
        tapID: AudioObjectID,
        aggregateDeviceID: AudioObjectID
    ) {
        stateLock.lock()
        guard sessions[pid] == nil else {
            stateLock.unlock()
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        let standardFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let playerNode = AVAudioPlayerNode()

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: standardFormat)

        let initialVolume = appVolumes[pid] ?? 1.0
        let isMuted = appMutes[pid] ?? false
        playerNode.volume = isMuted ? 0.0 : initialVolume

        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()

        let session = TapAudioSession(
            pid: pid,
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            playerNode: playerNode,
            format: standardFormat,
            volume: initialVolume,
            isMuted: isMuted
        )

        let sessionPtr = Unmanaged.passRetained(session).toOpaque()
        var procID: AudioDeviceIOProcID?

        let procStatus = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            tapAudioIOProc,
            sessionPtr,
            &procID
        )

        guard procStatus == noErr, let procID = procID else {
            print("❌ [PID: \(pid)] AudioDeviceCreateIOProcID failed: \(procStatus)")
            Unmanaged<TapAudioSession>.fromOpaque(sessionPtr).release()
            playerNode.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            stateLock.unlock()
            return
        }

        session.ioProcID = procID
        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            print("❌ [PID: \(pid)] AudioDeviceStart failed: \(startStatus)")
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            Unmanaged<TapAudioSession>.fromOpaque(sessionPtr).release()
            playerNode.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            stateLock.unlock()
            return
        }

        sessions[pid] = session
        sessionPointers[pid] = sessionPtr
        pendingPIDs.remove(pid)
        stateLock.unlock()

        print("🎧 [PID: \(pid)] Process tap active and streaming audio through AVAudioEngine (Echo-free).")
    }

    // MARK: - Core Audio Helpers

    /// Discovers all AudioObjectIDs associated with the application, including its helper/GPU processes.
    private func findAudioObjectIDs(for targetPID: pid_t) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        let fetchStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objectIDs)
        guard fetchStatus == noErr else { return [] }

        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let targetApp = NSRunningApplication(processIdentifier: targetPID)
        let targetName = targetApp?.localizedName ?? ""
        let targetBundleID = targetApp?.bundleIdentifier ?? ""

        var matchedObjectIDs: [AudioObjectID] = []

        for obj in objectIDs {
            var procPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let s = AudioObjectGetPropertyData(obj, &pidAddress, 0, nil, &pidSize, &procPID)
            guard s == noErr else { continue }

            // Match 1: Exact PID
            if procPID == targetPID {
                matchedObjectIDs.append(obj)
                continue
            }

            // Match 2: Matching bundle identifier or helper process name (e.g. Safari Graphics and Media)
            if let procApp = NSRunningApplication(processIdentifier: procPID) {
                if let bundle = procApp.bundleIdentifier, !bundle.isEmpty && bundle == targetBundleID {
                    matchedObjectIDs.append(obj)
                    continue
                }
                if let name = procApp.localizedName, !targetName.isEmpty && name.contains(targetName) {
                    matchedObjectIDs.append(obj)
                    continue
                }
            }
        }

        return matchedObjectIDs
    }

    private func getTapUID(for tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &uidSize, &uid)
        guard status == noErr, let retained = uid else { return nil }
        return retained.takeRetainedValue() as String
    }

    private func createAggregateDevice(tapUID: String, for pid: pid_t) -> AudioObjectID? {
        let tapDict: [String: Any] = [
            kAudioSubTapUIDKey: tapUID
        ]
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MVM-Agg-\(pid)",
            kAudioAggregateDeviceUIDKey: "com.mvm.agg.\(pid)." + UUID().uuidString,
            kAudioAggregateDeviceTapListKey: [tapDict],
            kAudioAggregateDeviceIsPrivateKey: true
        ]
        var aggregateDeviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
        guard status == noErr, aggregateDeviceID != 0 else {
            print("❌ [PID: \(pid)] AudioHardwareCreateAggregateDevice failed: \(status)")
            return nil
        }
        return aggregateDeviceID
    }

    // MARK: - Activity Polling (UI Indicator)

    private func startActivityPolling() {
        // Poll at 5 Hz on the main thread
        activityTimer = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.evaluateAudioActivity()
            }
    }

    private func evaluateAudioActivity() {
        stateLock.lock()
        let activeSessions = Array(sessions.values)
        stateLock.unlock()

        guard !activeSessions.isEmpty else {
            if !activeAudioPIDs.isEmpty {
                activeAudioPIDs.removeAll()
            }
            return
        }

        let now = mach_absolute_time()
        // Threshold: 600ms converted to mach ticks
        let thresholdNanos: UInt64 = 600_000_000
        let thresholdTicks = (thresholdNanos * UInt64(timebaseInfo.denom)) / UInt64(timebaseInfo.numer)

        var newlyActive = Set<pid_t>()
        for session in activeSessions {
            let lastActivity = session.lastAudioActivityMachTime
            if lastActivity > 0 && (now - lastActivity) < thresholdTicks {
                newlyActive.insert(session.pid)
            }
        }

        if newlyActive != activeAudioPIDs {
            activeAudioPIDs = newlyActive
        }
    }
}

// MARK: - Core Audio C Property Listener Callback

private func processListPropertyListener(
    inObjectID: AudioObjectID,
    inNumberAddresses: UInt32,
    inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData = inClientData else { return noErr }
    let mixer = Unmanaged<AudioMixer>.fromOpaque(inClientData).takeUnretainedValue()
    mixer.handleProcessListChanged()
    return noErr
}
