import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine

class AudioMixer: NSObject, ObservableObject, SCStreamOutput {
    private var engine = AVAudioEngine()
    
    // Uygulama düğümleri ve akış haritaları
    private var appNodes: [pid_t: AVAudioPlayerNode] = [:]
    private var appStreams: [pid_t: SCStream] = [:]
    private var streamToPID: [ObjectIdentifier: pid_t] = [:]
    private var appVolumes: [pid_t: Float] = [:]
    private var isReceivingAudio: [pid_t: Bool] = [:]
    
    // Ses iş parçacıkları ve UI etkileşimleri arasında veri yarışını (data race) önleyen kilit
    private let stateLock = NSLock()
    
    override init() {
        super.init()
        checkPermissions()
        setupEngine()
    }
    
    func checkPermissions() {
        if CGPreflightScreenCaptureAccess() {
            print("✅ İzin başarılı. Ses yakalamaya hazır.")
        } else {
            CGRequestScreenCaptureAccess()
        }
    }
    
    private func setupEngine() {
        _ = engine.mainMixerNode
        do {
            try engine.start()
            print("🎵 AVAudioEngine başarıyla başlatıldı.")
        } catch {
            print("❌ Ses motoru başlatılamadı: \(error)")
        }
    }
    
    // Hedef uygulamanın ses çıkışına kanca atar
    func startCapturingAudio(for pid: pid_t) {
        stateLock.lock()
        if appStreams[pid] != nil {
            stateLock.unlock()
            return // Zaten kanca atılmış, mükerrer başlatmayı önle
        }
        stateLock.unlock()
        
        Task {
            do {
                // 1. Sistemdeki açık ekranları ve uygulamaları bul
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                
                // 2. Hedef PID'yi bul
                guard let targetApp = content.applications.first(where: { $0.processID == pid }),
                      let display = content.displays.first else { return }
                
                print("⏳ [PID: \(pid)] Kanca atılıyor, hedef: \(targetApp.applicationName)...")
                
                // 3. Sadece bu uygulamanın sesini yakalayacak filtre ve konfigürasyon
                let filter = SCContentFilter(display: display, including: [targetApp], exceptingWindows: [])
                
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                
                // 4. Akışı (Stream) başlat
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                
                let queue = DispatchQueue(label: "audioQueue.\(pid)", qos: .userInteractive)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try await stream.startCapture()
                
                self.stateLock.lock()
                self.appStreams[pid] = stream
                self.streamToPID[ObjectIdentifier(stream)] = pid
                self.isReceivingAudio[pid] = false
                self.stateLock.unlock()
                
                print("🎧 [PID: \(pid)] Ses kancası başarıyla atıldı! (\(targetApp.applicationName))")
                
            } catch {
                print("❌ [PID: \(pid)] Kanca hatası: \(error.localizedDescription)")
            }
        }
    }
    
    // Uygulama bazlı ses kısma/artırma
    func setVolume(for pid: pid_t, volume: Double) {
        let vol = Float(volume)
        stateLock.lock()
        appVolumes[pid] = vol
        let node = appNodes[pid]
        stateLock.unlock()
        
        if let node = node {
            node.volume = vol
            print("🎚️ [PID: \(pid)] Ses anlık güncellendi: %\(Int(vol * 100))")
        }
    }
    
    // PID için AVAudioPlayerNode oluşturur veya var olanı döner (Format uyumlu bağlama ile)
    private func getOrCreatePlayerNode(for pid: pid_t, format: AVAudioFormat) -> AVAudioPlayerNode? {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        if let existingNode = appNodes[pid] {
            return existingNode
        }
        
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        
        // PlayerNode'u ana miksere gelen ses formatı ile bağlıyoruz
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        // Kullanıcının daha önce ayarladığı bir ses seviyesi varsa uygula
        let initialVolume = appVolumes[pid] ?? 1.0
        playerNode.volume = initialVolume
        
        if !engine.isRunning {
            try? engine.start()
        }
        
        playerNode.play()
        appNodes[pid] = playerNode
        print("🔗 [PID: \(pid)] Yeni AVAudioPlayerNode oluşturuldu ve mainMixerNode'a bağlandı. (Format: \(format.sampleRate)Hz, \(format.channelCount) kanal)")
        
        return playerNode
    }
    
    // CMSampleBuffer -> AVAudioPCMBuffer dönüşümü
    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        
        guard let audioFormat = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }
        
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
        
        // Apple'ın güvenli ve bellek kopyalamalı CoreMedia API'si:
        // Veriyi doğrudan pcmBuffer'ın tahsis ettiği bellek alanına kopyalar.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        
        guard status == noErr else {
            return nil
        }
        
        return pcmBuffer
    }
    
    // SCStreamOutput Protokolü: ScreenCaptureKit'ten gelen ham ses paketlerini işler
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        
        // 1. O(1) hızında PID eşleşmesi bul
        stateLock.lock()
        let targetPID = streamToPID[ObjectIdentifier(stream)]
        stateLock.unlock()
        
        guard let pid = targetPID else { return }
        
        // 2. İlk ses akışı başladığında bilgilendirme logu düş
        stateLock.lock()
        if isReceivingAudio[pid] == false {
            isReceivingAudio[pid] = true
            print("🔊 [PID: \(pid)] Aktif ses akışı gelmeye başladı!")
        }
        stateLock.unlock()
        
        // 3. CMSampleBuffer -> AVAudioPCMBuffer dönüşümü
        guard let pcmBuffer = createPCMBuffer(from: sampleBuffer) else {
            return
        }
        
        // 4. Hedef PID'nin PlayerNode'unu al (veya ilk defa geliyorsa dinamik oluşturup bağla)
        guard let playerNode = getOrCreatePlayerNode(for: pid, format: pcmBuffer.format) else {
            return
        }
        
        // 5. Motorun ve player'ın çalıştığından emin ol
        if !playerNode.isPlaying {
            playerNode.play()
        }
        
        // 6. PCMBuffer'ı ses motoruna zamanla (schedule)
        playerNode.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)
    }
    
    // İsteğe bağlı: Kancayı kaldırma ve kaynak temizliği
    func stopCapturingAudio(for pid: pid_t) {
        stateLock.lock()
        let stream = appStreams.removeValue(forKey: pid)
        if let stream = stream {
            streamToPID.removeValue(forKey: ObjectIdentifier(stream))
        }
        let node = appNodes.removeValue(forKey: pid)
        isReceivingAudio.removeValue(forKey: pid)
        appVolumes.removeValue(forKey: pid)
        stateLock.unlock()
        
        if let node = node {
            node.stop()
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        
        if let stream = stream {
            Task {
                try? await stream.stopCapture()
                print("🛑 [PID: \(pid)] Ses kancası durduruldu ve temizlendi.")
            }
        }
    }
}

