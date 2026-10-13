import SwiftUI
import AppKit
import Combine
// Uygulama verilerini tutacağımız model
struct AppItem: Identifiable {
    let id = UUID()
    let pid: pid_t
    let name: String
    let icon: NSImage
    var volume: Double = 1.0 // Varsayılan ses seviyesi %100
}

// Arka planda çalışan uygulamaları bulan kontrolcü
class AudioController: ObservableObject {
    @Published var activeApps: [AppItem] = []
    
    init() {
        fetchRunningApps()
    }
    
    func fetchRunningApps() {
        let workspace = NSWorkspace.shared
        // Sadece arayüzü olan (Dock'ta görünen) uygulamaları filtrele
        let runningApps = workspace.runningApplications.filter { $0.activationPolicy == .regular }
        
        self.activeApps = runningApps.compactMap { app in
            guard let name = app.localizedName, let icon = app.icon else { return nil }
            return AppItem(pid: app.processIdentifier, name: name, icon: icon)
        }
    }
}

// Görsel Arayüz
struct ContentView: View {
    @StateObject private var audioController = AudioController()
    @StateObject private var audioMixer = AudioMixer()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac Volume Mixer (MVM)")
                .font(.headline)
                .padding(.bottom, 5)
            
            Divider()
            
            // Uygulamaların listelendiği kaydırılabilir alan
            ScrollView {
                VStack(spacing: 15) {
                    ForEach($audioController.activeApps) { $app in
                        HStack {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                            
                            Text(app.name)
                                .frame(width: 90, alignment: .leading)
                                .lineLimit(1)

                            Slider(value: $app.volume, in: 0...1)
                                .onChange(of: app.volume) { oldValue,newValue in
                                    // Kaydırıcı her hareket ettiğinde motoru PID ve yeni ses değeriyle uyar
                                    audioMixer.setVolume(for: app.pid, volume: newValue)
                                }.onAppear {
                                    // Arayüzde uygulama göründüğü an sesini yakalamaya başla
                                    audioMixer.startCapturingAudio(for: app.pid)
                                }
                        }
                    }
                }
                .padding(.trailing, 5)
            }
            .frame(minWidth: 300, minHeight: 200, maxHeight: 400)

            
            Divider()
            
            Button("Çıkış") {
                NSApplication.shared.terminate(nil)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
        .frame(width: 320)
    }
}

