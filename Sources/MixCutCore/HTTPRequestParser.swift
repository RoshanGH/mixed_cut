import Foundation

/// 解析出的一个完整 HTTP 请求
public struct ParsedHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let body: Data
    /// 本请求在缓冲区中占用的字节数（keep-alive 时调用方据此裁掉已消费部分）
    public let consumedBytes: Int
}

/// 极简 HTTP/1.1 请求解析（仅支撑本机 MCP 场景：短头部 + Content-Length 定长 body）
public enum HTTPRequestParser {
    /// 缓冲区中还没有完整请求时返回 nil，调用方应继续收包后重试
    public static func parse(buffer: Data) -> ParsedHTTPRequest? {
        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let terminatorRange = buffer.range(of: headerTerminator) else { return nil }

        let headerData = buffer.subdata(in: buffer.startIndex..<terminatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3, parts[2].hasPrefix("HTTP/") else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = terminatorRange.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyEnd)
        return ParsedHTTPRequest(method: method, path: path, body: body, consumedBytes: consumed)
    }
}
