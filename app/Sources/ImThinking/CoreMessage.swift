import Foundation

struct CoreMessage: Decodable {
    let version: Int
    let sequence: UInt64?
    let type: String
    let coreVersion: String?
    let session: UInt32?
    let agent: String?
    let phase: String?
    let intensity: Double?
    let toolClass: String?
    let status: String?
    let code: String?
    let recoverable: Bool?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case sequence = "seq"
        case type
        case coreVersion = "core_version"
        case session
        case agent
        case phase
        case intensity
        case toolClass = "tool_class"
        case status
        case code
        case recoverable
    }
}
