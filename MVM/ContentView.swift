import SwiftUI
import AppKit
import Combine

// Uygulama verilerini tutacağımız model
struct AppItem: Identifiable, Equatable {
    let id: pid_t // PID doğrudan benzersiz kimlik olarak kullanılır
    var pid: pid_t { id }
    let name: String
    let icon: NSImage
    var volume: Double = 1.0 // Varsayılan ses seviyesi %100
    var isMuted: Bool = false
    
    init(pid: pid_t, name: String, icon: NSImage, volume: Double = 1.0, isMuted: Bool = false) {
        self.id = pid
        self.name = name
        self.icon = icon
        self.volume = volume
        self.isMuted = isMuted
    }
    
    static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.id == rhs.id && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
    }
}

// Açık olan uygulamaları dinamik olarak takip eden kontrolcü (Lifecycle Manager)
class AudioController: ObservableObject {
    @Published var activeApps: [AppItem] = []
    @Published var searchText: String = ""
    private var cancellables = Set<AnyCancellable>()
    
    var filteredApps: [AppItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return activeApps
        } else {
            return activeApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }
    
    init() {
        fetchRunningApps()
        setupObservers()
    }
    
    func fetchRunningApps() {
        let workspace = NSWorkspace.shared
        let myPID = ProcessInfo.processInfo.processIdentifier
        
        // Sadece arayüzü olan (Dock'ta görünen) ve MVM kendisi olmayan uygulamaları filtrele
        let runningApps = workspace.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != myPID
        }
        
        // Yenileme anında kullanıcının mevcut ses ve mute ayarlarını koru
        var volumeMap: [pid_t: (Double, Bool)] = [:]
        for app in activeApps {
            volumeMap[app.pid] = (app.volume, app.isMuted)
        }
        
        self.activeApps = runningApps.compactMap { app in
            guard let name = app.localizedName, let icon = app.icon else { return nil }
            let existing = volumeMap[app.processIdentifier]
            return AppItem(
                pid: app.processIdentifier,
                name: name,
                icon: icon,
                volume: existing?.0 ?? 1.0,
                isMuted: existing?.1 ?? false
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    // Sistemdeki uygulama açılma/kapanma olaylarını anlık dinle
    private func setupObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        
        // Yeni bir uygulama başlatıldığında
        nc.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in
                self?.handleAppLaunch(app)
            }
            .store(in: &cancellables)
            
        // Bir uygulama kapandığında
        nc.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in
                self?.handleAppTermination(app)
            }
            .store(in: &cancellables)
    }
    
    private func handleAppLaunch(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let name = app.localizedName,
              let icon = app.icon else { return }
        
        if !activeApps.contains(where: { $0.pid == app.processIdentifier }) {
            withAnimation(.easeInOut(duration: 0.2)) {
                activeApps.append(AppItem(pid: app.processIdentifier, name: name, icon: icon))
                activeApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
    }
    
    private func handleAppTermination(_ app: NSRunningApplication) {
        withAnimation(.easeInOut(duration: 0.2)) {
            activeApps.removeAll { $0.pid == app.processIdentifier }
        }
    }
}

// Görsel Arayüz (Menü Çubuğu Penceresi)
struct ContentView: View {
    @StateObject private var audioController = AudioController()
    @StateObject private var audioMixer = AudioMixer()
    @State private var masterVolume: Double = 1.0
    @State private var isMasterMuted: Bool = false
    @State private var showOnlyAudioApps: Bool = true
    
    private func isAppVisible(_ app: AppItem) -> Bool {
        let matchesSearch = audioController.searchText.isEmpty || app.name.localizedCaseInsensitiveContains(audioController.searchText)
        let hasAudio = audioMixer.audioCapablePIDs.contains(app.pid) || audioMixer.activeAudioPIDs.contains(app.pid)
        let matchesAudio = !showOnlyAudioApps || hasAudio
        return matchesSearch && matchesAudio
    }
    
    private var visibleAppCount: Int {
        audioController.activeApps.filter { isAppVisible($0) }.count
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // MARK: - Başlık ve Üst Bilgi
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Volume Mixer")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(showOnlyAudioApps ? "\(visibleAppCount) sesli uygulama" : "\(visibleAppCount) açık uygulama")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showOnlyAudioApps.toggle()
                    }
                } label: {
                    Image(systemName: showOnlyAudioApps ? "speaker.wave.2.circle.fill" : "app.badge.checkmark")
                        .font(.system(size: 13))
                        .foregroundColor(showOnlyAudioApps ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(showOnlyAudioApps ? "Sadece sesli uygulamalar gösteriliyor (Tümünü görmek için tıkla)" : "Tüm açık uygulamalar gösteriliyor (Sadece seslileri görmek için tıkla)")
                
                Button {
                    audioController.fetchRunningApps()
                    audioMixer.refreshAudioCapablePIDs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Uygulama Listesini Yenile")
            }
            
            // MARK: - İzin Uyarı Banner'ı (YENİ EKLENEN KISIM)
            if !audioMixer.hasPermission {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Sistem İzni Gerekiyor")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Ayarları Aç") {
                            openPrivacySettings()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                    
                    Text("Uygulamanın sesleri kontrol edebilmesi için Sistem Ayarları > Gizlilik ve Güvenlik > Ekran ve Sistem Sesi Kaydı bölümünden izin vermeli ve uygulamayı yeniden başlatmalısınız.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                )
            }
            
            // MARK: - Genel Ses (Master Volume)
            HStack(spacing: 8) {
                Button {
                    isMasterMuted.toggle()
                    audioMixer.setMasterVolume(isMasterMuted ? 0 : masterVolume)
                } label: {
                    Image(systemName: isMasterMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .foregroundColor(isMasterMuted ? .red : .accentColor)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(isMasterMuted ? "Genel Sesi Aç" : "Genel Sesi Kapat")
                
                Text("Genel")
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(width: 36, alignment: .leading)
                
                Slider(value: $masterVolume, in: 0...1)
                    .disabled(isMasterMuted || !audioMixer.hasPermission) // İzin yoksa slider'ı da inaktif yap
                    .opacity((isMasterMuted || !audioMixer.hasPermission) ? 0.4 : 1.0)
                    .onChange(of: masterVolume) { _, newValue in
                        if !isMasterMuted {
                            audioMixer.setMasterVolume(newValue)
                        }
                    }
                
                Text(isMasterMuted ? "Mute" : "%\(Int(masterVolume * 100))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isMasterMuted ? .secondary : .primary)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
            .cornerRadius(8)
            
            // Arama Çubuğu (4'ten fazla uygulama olduğunda kolaylık sağlar)
            if visibleAppCount > 4 || !audioController.searchText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    TextField("Uygulama ara...", text: $audioController.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !audioController.searchText.isEmpty {
                        Button {
                            audioController.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(6)
            }
            
            Divider()
            
            // MARK: - Uygulamalar Listesi
            if visibleAppCount == 0 {
                VStack(spacing: 8) {
                    Image(systemName: showOnlyAudioApps ? "speaker.slash" : "app.dashed")
                        .font(.system(size: 26))
                        .foregroundColor(.secondary)
                    Text(
                        !audioController.searchText.isEmpty
                            ? "Eşleşen uygulama yok"
                            : (showOnlyAudioApps ? "Aktif ses çıkışı olan uygulama bulunamadı" : "Açık uygulama bulunamadı")
                    )
                    .font(.callout)
                    .foregroundColor(.secondary)
                    
                    if showOnlyAudioApps && audioController.searchText.isEmpty {
                        Text("Ses desteği olan bir uygulama açıldığında otomatik listelenir.")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach($audioController.activeApps) { $app in
                            if isAppVisible(app) {
                                AppRowView(app: $app, audioMixer: audioMixer)
                            }
                        }
                    }
                    .padding(.trailing, 4)
                    .padding(.vertical, 2)
                }
                .frame(minWidth: 320, minHeight: 200, maxHeight: 420)
            }
            
            Divider()
            
            // MARK: - Alt Bilgi ve Çıkış
            HStack {
                Text("MVM v1.0")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Çıkış") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            audioMixer.refreshAudioCapablePIDs()
        }
    }
    
    // MARK: - Yardımcı Fonksiyonlar
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// Tek bir uygulamanın satır görünümü
struct AppRowView: View {
    @Binding var app: AppItem
    @ObservedObject var audioMixer: AudioMixer
    
    var isAudioActive: Bool {
        audioMixer.activeAudioPIDs.contains(app.pid)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Uygulama Simgesi
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
            
            // Uygulama İsmi ve Ses Akış Göstergesi
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    
                    if isAudioActive {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .help("Ses çıkışı aktif")
                    }
                }
            }
            .frame(width: 88, alignment: .leading)
            
            // Ses Kaydırıcısı
            Slider(value: $app.volume, in: 0...1)
                .disabled(app.isMuted || !audioMixer.hasPermission)
                .opacity((app.isMuted || !audioMixer.hasPermission) ? 0.4 : 1.0)
                .onChange(of: app.volume) { _, newValue in
                    if !app.isMuted {
                        audioMixer.setVolume(for: app.pid, volume: newValue)
                    }
                }
                .onAppear {
                    audioMixer.startCapturingAudio(for: app.pid)
                }
            
            // Yüzde Göstergesi
            Text(app.isMuted ? "Mute" : "%\(Int(app.volume * 100))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(app.isMuted ? .secondary : .primary)
                .frame(width: 38, alignment: .trailing)
            
            // Sessize Alma (Mute) Butonu
            Button {
                app.isMuted.toggle()
                audioMixer.setMuted(for: app.pid, isMuted: app.isMuted)
            } label: {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : (app.volume == 0 ? "speaker.slash" : "speaker.wave.2.fill"))
                    .foregroundColor(app.isMuted ? .red : (isAudioActive ? .accentColor : .secondary))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!audioMixer.hasPermission) // İzin yoksa butonları kapat
            .help(app.isMuted ? "Sesi Aç" : "Sessize Al")
        }
    }
}

