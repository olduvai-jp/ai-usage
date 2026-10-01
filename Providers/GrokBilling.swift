import Foundation

/// Strict decoding of the consumer billing RPC's known fields. Never scans arbitrary bytes for a percentage.
enum GrokBilling {
    private struct Field {
        let number: Int
        var integer: UInt64? = nil
        var bits: UInt32? = nil
        var bytes: Data? = nil
    }

    static func validateStatus(_ raw: String) throws {
        guard let status = Int(raw) else { throw UsageError.invalidResponse }
        if status == 7 || status == 16 {
            throw UsageError.authentication("Grokの利用枠へのアクセスが拒否されました。grok login で再接続してください。")
        }
        guard status == 0 else { throw UsageError.invalidResponse }
    }

    static func windows(_ data: Data, now: Date = Date()) throws -> [QuotaWindow] {
        let bytes = Array(data)
        guard bytes.count <= 2_000_000 else { throw UsageError.invalidResponse }
        var offset = 0
        var payload: Data?
        var sawTrailer = false
        while offset < bytes.count {
            guard bytes.count - offset >= 5, !sawTrailer else { throw UsageError.invalidResponse }
            let flag = bytes[offset]
            let length = bytes[(offset + 1)...(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 5
            guard length <= bytes.count - offset else { throw UsageError.invalidResponse }
            let frame = Data(bytes[offset..<(offset + length)])
            offset += length
            switch flag {
            case 0:
                guard payload == nil else { throw UsageError.invalidResponse }
                payload = frame
            case 128:
                sawTrailer = true
                guard let text = String(data: frame, encoding: .utf8) else { throw UsageError.invalidResponse }
                let statuses = text.components(separatedBy: .newlines).compactMap { line -> String? in
                    let pair = line.split(separator: ":", maxSplits: 1)
                    guard pair.count == 2, pair[0].lowercased() == "grpc-status" else { return nil }
                    return pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard statuses.count == 1 else { throw UsageError.invalidResponse }
                try validateStatus(statuses[0])
            default: throw UsageError.invalidResponse
            }
        }
        guard let payload else { throw UsageError.invalidResponse }
        let root = try fields(payload)
        guard let configBytes = try one(1, in: root)?.bytes else { throw UsageError.invalidResponse }
        let config = try fields(configBytes)
        let usageField = try one(1, in: config)
        let periodBytes = try one(8, in: config)?.bytes
        let period = try periodBytes.map(fields) ?? []
        let periodType = try one(1, in: period)?.integer
        let start = try timestamp(one(2, in: period))
        let end = try timestamp(one(3, in: period))
        let reset = try end ?? timestamp(one(5, in: config))
        let used: Double
        if let usageField {
            guard let bits = usageField.bits else { throw UsageError.invalidResponse }
            used = Double(Float(bitPattern: bits))
            guard used.isFinite, used >= 0 else { throw UsageError.invalidResponse }
        } else {
            // Proto3 omits zero scalars. Only accept that contract with a validated active period.
            guard periodType == 1 || periodType == 2,
                  let start, let end, start <= now, end > now else { throw UsageError.invalidResponse }
            used = 0
        }
        var kind: WindowKind = .current
        if let start, let end, end > start {
            let minutes = end.timeIntervalSince(start) / 60
            if abs(minutes - 10080) < 1 { kind = .weekly }
            else if (40320...44640).contains(minutes) { kind = .monthly }
            else if minutes <= 1440 { kind = .short }
        }
        return [QuotaWindow(id: "grok-subscription", kind: kind, title: "SuperGrok \(kind.label)",
                            usedPercent: used, resetsAt: reset)]
    }

    private static func one(_ number: Int, in fields: [Field]) throws -> Field? {
        let matches = fields.filter { $0.number == number }
        guard matches.count <= 1 else { throw UsageError.invalidResponse }
        return matches.first
    }

    private static func timestamp(_ field: Field?) throws -> Date? {
        guard let field else { return nil }
        guard let data = field.bytes,
              let seconds = try one(1, in: fields(data))?.integer,
              (1_000_000_000...4_000_000_000).contains(seconds) else { throw UsageError.invalidResponse }
        return Date(timeIntervalSince1970: Double(seconds))
    }

    private static func fields(_ data: Data) throws -> [Field] {
        let bytes = Array(data)
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw UsageError.invalidResponse }
                let byte = bytes[offset]
                offset += 1
                guard index < 9 || byte <= 1 else { throw UsageError.invalidResponse }
                value |= UInt64(byte & 127) << (index * 7)
                if byte & 128 == 0 { return value }
            }
            throw UsageError.invalidResponse
        }
        var result: [Field] = []
        while offset < bytes.count {
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= 536_870_911 else { throw UsageError.invalidResponse }
            var field = Field(number: Int(tag >> 3))
            switch tag & 7 {
            case 0: field.integer = try varint()
            case 1:
                guard bytes.count - offset >= 8 else { throw UsageError.invalidResponse }
                offset += 8
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - offset) else { throw UsageError.invalidResponse }
                field.bytes = Data(bytes[offset..<(offset + Int(length))])
                offset += Int(length)
            case 5:
                guard bytes.count - offset >= 4 else { throw UsageError.invalidResponse }
                field.bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
                offset += 4
            default: throw UsageError.invalidResponse
            }
            result.append(field)
        }
        return result
    }
}
