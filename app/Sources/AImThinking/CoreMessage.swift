import Foundation

struct CoreMessage: Decodable {
    let version: Int
    let type: String
    let session: UInt32?
    let agent: String?
    let phase: String?
    let intensity: Double?
    let toolClass: String?
    let status: String?
    let code: String?
    let component: String?
    let recoverable: Bool?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case session
        case agent
        case phase
        case intensity
        case toolClass = "tool_class"
        case status
        case code
        case component
        case recoverable
    }
}
