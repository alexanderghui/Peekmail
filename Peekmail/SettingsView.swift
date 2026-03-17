import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 400, height: 250)
    }
}

enum AlertSound: String, CaseIterable, Identifiable {
    case glass = "Glass"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case tink = "Tink"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

struct GeneralSettingsView: View {
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("audioAlerts") private var audioAlerts = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("alertSound") private var alertSound = AlertSound.glass.rawValue

    var body: some View {
        Form {
            Toggle("Show in Dock", isOn: $showInDock)
                .onChange(of: showInDock) { _, newValue in
                    NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                }

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        print("Failed to update login item: \(error)")
                    }
                }

            Toggle("Play Sound on New Mail", isOn: $audioAlerts)

            if audioAlerts {
                Picker("Alert Sound", selection: $alertSound) {
                    ForEach(AlertSound.allCases) { sound in
                        Text(sound.displayName).tag(sound.rawValue)
                    }
                }
                .onChange(of: alertSound) { _, newValue in
                    NSSound(named: NSSound.Name(newValue))?.play()
                }
            }
        }
        .padding(20)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Peekmail")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .foregroundColor(.secondary)

            Text("A lightweight Gmail client for your menu bar.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
