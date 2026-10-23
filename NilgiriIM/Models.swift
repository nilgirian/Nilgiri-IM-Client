import Foundation

struct LoginResponse: Decodable {
    let token: String
    let sessionId: String
    let character: String
    let lines: [LineDTO]?
}

struct LineDTO: Decodable, Identifiable, Equatable {
    var id: Int64 { seq }
    let seq: Int64
    let at: Int64
    let kind: String
    let text: String
}

struct SinceResponse: Decodable {
    let closed: Bool
    let lines: [LineDTO]
}

struct ErrorResponse: Decodable {
    let error: String
}
