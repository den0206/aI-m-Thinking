import Foundation

struct CoreMessage: Decodable {
    let version: Int
    let sequence: UInt64?
    let type: String
    let coreVersion: String?
    let agent: String?
    let phase: String?
    let intensity: Double?
    let status: String?
    let code: String?
    let recoverable: Bool?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case sequence = "seq"
        case type
        case coreVersion = "core_version"
        case agent
        case phase
        case intensity
        case status
        case code
        case recoverable
    }
}
