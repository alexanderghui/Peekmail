import AppKit
import os

/// Checks GitHub Releases for a newer version and offers to download it.
/// No framework dependency (Sparkle doesn't fit the sandbox or the
/// no-external-packages rule) — updates are published as GitHub Releases
/// with the DMG attached, and the user installs by opening the DMG.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let logger = Logger(subsystem: "com.peekmail.app", category: "updates")
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/alexanderghui/Peekmail/releases/latest")!
    private let lastOfferedVersionKey = "lastOfferedUpdateVersion"

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Silent unless a new version is found, and offers each version only once.
    func checkInBackground() {
        check(userInitiated: false)
    }

    /// Always reports a result, including "up to date" and errors.
    func checkManually() {
        check(userInitiated: true)
    }

    private func check(userInitiated: Bool) {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }

            guard let data, error == nil else {
                self.logger.error("Update check failed: \(error?.localizedDescription ?? "no data")")
                if userInitiated {
                    self.presentSimpleAlert(title: "Update Check Failed",
                                            message: "Couldn't reach GitHub to check for updates. Please try again later.")
                }
                return
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let release = try? decoder.decode(Release.self, from: data) else {
                self.logger.error("Update check failed: could not parse release JSON")
                if userInitiated {
                    self.presentSimpleAlert(title: "Update Check Failed",
                                            message: "No published releases were found.")
                }
                return
            }

            let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            self.logger.info("Update check: current=\(self.currentVersion, privacy: .public) latest=\(latest, privacy: .public)")

            guard self.isVersion(latest, newerThan: self.currentVersion) else {
                if userInitiated {
                    self.presentSimpleAlert(title: "You're Up to Date",
                                            message: "Peekmail \(self.currentVersion) is the latest version.")
                }
                return
            }

            // Background checks only offer a given version once
            if !userInitiated,
               UserDefaults.standard.string(forKey: self.lastOfferedVersionKey) == latest {
                return
            }
            UserDefaults.standard.set(latest, forKey: self.lastOfferedVersionKey)

            let dmgURL = release.assets.first { $0.name.hasSuffix(".dmg") }?.browserDownloadUrl ?? release.htmlUrl
            self.presentUpdateAlert(version: latest, downloadURL: dmgURL)
        }.resume()
    }

    private func isVersion(_ a: String, newerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(aParts.count, bParts.count) {
            let x = i < aParts.count ? aParts[i] : 0
            let y = i < bParts.count ? bParts[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func presentUpdateAlert(version: String, downloadURL: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Peekmail \(version) Is Available"
            alert.informativeText = "You have version \(self.currentVersion). Download the update, then drag Peekmail to your Applications folder to install it."
            alert.addButton(withTitle: "Download Update")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: downloadURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func presentSimpleAlert(title: String, message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.runModal()
        }
    }
}
