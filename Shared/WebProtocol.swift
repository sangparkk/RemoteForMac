import Foundation

struct LocalHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    static func parse(_ data: Data) throws -> Self? {
        guard data.count <= 70_000 else { throw LinkError.invalidMessage }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 8_192 { throw LinkError.invalidMessage }; return nil
        }
        guard boundary.lowerBound <= 8_192,
              let text = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw LinkError.invalidMessage }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(String(first[0])) else { throw LinkError.invalidMessage }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw LinkError.invalidMessage }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw LinkError.invalidMessage }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), (0...60_000).contains(length) else { throw LinkError.invalidMessage }
        let end = boundary.upperBound + length
        guard data.count >= end else { return nil }
        guard data.count == end else { throw LinkError.invalidMessage }
        return Self(method: String(first[0]), path: String(first[1]), headers: headers, body: data[boundary.upperBound..<end])
    }
}

struct WebRemoteAction: Codable {
    var type: String
    var x: Double?
    var y: Double?
    var points: [WebPoint]?
    var key: RemoteKey?
    var service: Service?
    var request: UUID?
    var session: UUID?
    var snapshot: TextSnapshot?
    struct WebPoint: Codable { let x: Double; let y: Double }
    func validate() throws {
        let allowed = ["touch", "cancel", "key", "activate", "keyboard", "text", "endText", "submit", "backspace", "heartbeat", "disconnect"]
        guard allowed.contains(type) else { throw LinkError.invalidMessage }
        if let points { guard points.count <= 5, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 10_000 && abs($0.y) < 10_000 }) else { throw LinkError.invalidMessage } }
        if let x { guard x.isFinite, (0.5...3).contains(x) else { throw LinkError.invalidMessage } }
        if let y { guard y == -1 || y == 1 else { throw LinkError.invalidMessage } }
        if let snapshot { try snapshot.validate() }
    }
}
struct WebRemoteBatch: Codable {
    let client: UUID
    let sequence: UInt64
    let actions: [WebRemoteAction]
}
/// A duplicate HTTP request must never repeat a click or key press.
struct WebSequence {
    private(set) var next: UInt64 = 1
    mutating func accept(_ sequence: UInt64) -> Bool {
        guard sequence == next, next < UInt64.max else { return false }
        next += 1; return true
    }
}

/// DNS hostnames are case-insensitive; Safari normalizes them to lowercase.
enum WebOriginPolicy {
    static func accepts(host: String?, origin: String?, authorities: Set<String>) -> Bool {
        guard let host = host?.lowercased(), authorities.contains(where: { $0.lowercased() == host }) else { return false }
        return origin == nil || origin?.lowercased() == "http://" + host
    }
}
