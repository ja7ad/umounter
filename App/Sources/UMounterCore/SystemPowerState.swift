import Foundation
import Observation

/// Whether macOS Low Power Mode is on, as an observable value. The app target
/// feeds it from `ProcessInfo` (`isLowPowerModeEnabled` +
/// `NSProcessInfoPowerStateDidChange`); tests set it directly.
@MainActor
@Observable
public final class SystemPowerState {
    public var isLowPowerMode: Bool

    public init(isLowPowerMode: Bool = false) {
        self.isLowPowerMode = isLowPowerMode
    }
}
