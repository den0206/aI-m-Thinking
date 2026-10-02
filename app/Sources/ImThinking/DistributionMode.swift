import Foundation

enum DistributionMode: String {
    case direct
    case appStore = "app-store"

    static var current: Self {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ImThinkingDistribution") as? String,
              let mode = Self(rawValue: raw)
        else {
            return .direct
        }
        return mode
    }
}
