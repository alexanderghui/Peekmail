# Peekmail - Project Context for Claude Code

## What is Peekmail?
A native macOS menu bar Gmail client built in Swift. Replaces "Made for Gmail" by Fiplab which stopped working (blank WebView). Built entirely from scratch with no external dependencies.

## Architecture

### Core Tech
- **Swift + SwiftUI + AppKit** (no external packages)
- **WKWebView** for Gmail rendering with persistent sessions
- **Gmail Atom feed** (`https://mail.google.com/mail/feed/atom`) for unread count polling every 15 seconds
- **UNUserNotificationCenter** for desktop notifications
- **NSStatusItem** for menu bar presence
- `LSUIElement = true` in Info.plist to hide from dock by default
- App Sandbox with network.client entitlement
- Build with: `xcodebuild -scheme Peekmail -configuration Debug -derivedDataPath build`
- Launch with: `open build/Build/Products/Debug/Peekmail.app`

### File Structure
```
Peekmail/
├── PeekmailApp.swift          # @main entry point, NSApplicationDelegateAdaptor
├── AppDelegate.swift          # Main controller: menu bar, window, feed polling, notifications
├── AccountManager.swift       # Multi-account management with isolated WKWebsiteDataStores
├── GmailWebView.swift         # NSViewRepresentable WKWebView wrapper
├── MainWindowView.swift       # SwiftUI view with optional account sidebar
├── NotificationManager.swift  # UNUserNotification delegate, rich notifications
├── SettingsView.swift         # General + About tabs (dock toggle, sounds, launch at login)
├── Info.plist                 # LSUIElement=true, min macOS 13.0
├── Peekmail.entitlements      # App Sandbox + network.client
└── Assets.xcassets/           # App icon (dark gradient + white envelope outline)
generate_icon.swift            # Standalone Swift script to regenerate app icons
```

### Key Design Decisions
- **Atom feed over title parsing**: Originally parsed Gmail page title for unread count, but this broke when navigating to Drafts/Sent. Atom feed works regardless of which Gmail view is active.
- **First-poll seeding**: `hasCompletedFirstPoll` flag prevents notification spam on app launch. First poll silently seeds known email IDs; subsequent polls notify for new IDs only.
- **Cookie extraction**: Atom feed auth uses cookies extracted from WKWebView's data store, passed as Cookie header in URLRequest.
- **Isolated data stores**: Each Gmail account gets its own `WKWebsiteDataStore(forIdentifier: UUID)` for cookie isolation.
- **Manual NSWindow for settings**: SwiftUI `Settings` scene doesn't work with `.accessory` activation policy, so settings uses a manually created NSWindow with NSHostingView.
- **Window hide vs quit**: Cmd+W / close button hides window (app stays in menu bar). Cmd+Q quits.
- **Icon generation**: `generate_icon.swift` draws directly to CGContext (not NSImage.lockFocus) to avoid retina scaling issues that caused grey borders.

### How Feed Polling Works (AppDelegate.swift)
1. Timer fires every 15 seconds
2. For each account: extract cookies from WKWebsiteDataStore
3. Fetch `https://mail.google.com/mail/feed/atom` with Cookie header
4. Parse XML response: `<fullcount>` for total unread, `<entry>` elements for individual emails
5. Compare entry IDs against `notifiedEmailIds` set
6. New IDs → send rich notification (sender, subject, snippet) + play alert sound
7. Update menu bar icon (red filled envelope + count, or grey outline for 0)

### Notification System
- Rich notifications show: sender name (title), subject (subtitle), email snippet (body)
- `content.sound = nil` — app handles sound separately via NSSound
- `willPresent` returns `[.banner]` only (no system sound to avoid double-ding)
- 5 alert sounds: Glass, Ping, Pop, Purr, Tink (configurable in Settings)

## Pending Tasks (in priority order)

### 1. Notification Click → Open Email Thread
**Status**: ✅ Complete (2026-03-17)
Fixed by: adding `AppDelegate.shared` static ref (SwiftUI `@NSApplicationDelegateAdaptor` breaks `NSApp.delegate as? AppDelegate`), moving `UNUserNotificationCenter.delegate` setup to `NotificationManager.init()`, converting Atom feed `message_id` to Gmail `#inbox/messageId` URL format, and keeping activation policy as `.regular` instead of reverting to `.accessory`.

### 1b. WKWebView Stale Cache
**Status**: In progress — not yet resolved.
Gmail webview doesn't reflect changes made on other devices (e.g. deleting email on phone). Even after clearing disk/memory/fetch cache + service workers and doing fresh navigation with `.reloadIgnoringLocalAndRemoteCacheData`, stale content persists. `reloadFromOrigin()` also doesn't work. Need to investigate further — possibly Gmail's IndexedDB/localStorage holding stale state, or need to clear `WKWebsiteDataTypeOfflineWebApplicationCache` / `WKWebsiteDataTypeIndexedDBDatabases`.

### 2. Faster Unread Count Update After Reading
**Status**: Not implemented.
After reading an email in Peekmail, the menu bar count takes up to 15 seconds to update (next poll cycle). Options:
- Watch WKWebView page title for changes and trigger immediate poll (tried this, caused issues with too-rapid polling — needs debounce/throttle)
- Inject JavaScript to observe Gmail DOM changes
- Reduce poll interval when window is focused

### 3. Clean Up Debug Logging
Remove any remaining `print()` statements added during troubleshooting.

### 4. Title Bar Transparency
Was reported as not fully seamless. May need verification — `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `.fullSizeContentView`, `backgroundColor = .white` are all set.

## Build & Run
```bash
cd /path/to/Peekmail
xcodebuild -scheme Peekmail -configuration Debug -derivedDataPath build
open build/Build/Products/Debug/Peekmail.app
```

## Regenerate App Icon
```bash
swift generate_icon.swift
# Then rebuild the app
```
