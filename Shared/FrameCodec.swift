import Foundation

/// Four-byte big-endian length plus JSON. Only feed this after peer authentication.
struct FrameDecoder {
    static let maximumPayload = 131_072
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        // Callers read at most 64 KiB at a time, limiting incomplete-frame memory use.
        guard data.count <= 65_536 else { throw FrameError.tooLarge }
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumPayload else {
                buffer.removeAll(); throw FrameError.tooLarge
            }
            guard buffer.count >= length + 4 else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(length + 4))
        }
        return frames
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard !payload.isEmpty, payload.count <= maximumPayload else { throw FrameError.tooLarge }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }
    enum FrameError: Error { case tooLarge }
}
