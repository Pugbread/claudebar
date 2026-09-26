import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    var sounds: Bool {
        didSet { UserDefaults.standard.set(sounds, forKey: Keys.sounds) }
    }
    var glow: Bool {
        didSet { UserDefaults.standard.set(glow, forKey: Keys.glow) }
    }
    /// Icon-only activity in the collapsed bar, for crowded menu bars.
    var compactBar: Bool {
        didSet { UserDefaults.standard.set(compactBar, forKey: Keys.compactBar) }
    }
    var allDisplays: Bool {
        didSet {
            UserDefaults.standard.set(allDisplays, forKey: Keys.allDisplays)
            onDisplaysChanged?()
        }
    }
    var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Claudebar: launch at login change failed: \(error)")
            }
        }
    }

    @ObservationIgnored var onDisplaysChanged: (() -> Void)?

    private enum Keys {
        static let sounds = "sounds"
        static let glow = "glow"
        static let compactBar = "compactBar"
        static let allDisplays = "allDisplays"
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.sounds: true, Keys.glow: true, Keys.allDisplays: true])
        sounds = defaults.bool(forKey: Keys.sounds)
        glow = defaults.bool(forKey: Keys.glow)
        compactBar = defaults.bool(forKey: Keys.compactBar)
        allDisplays = defaults.bool(forKey: Keys.allDisplays)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
