import Foundation
import Network

/// 内嵌本地 MCP server 的 HTTP 传输壳。
/// 只绑定 127.0.0.1，只接受 POST /mcp；JSON-RPC 语义全部委托给注入的 handler。
actor MCPServer {
    private let port: UInt16
    private let handler: @Sendable (Data) async -> Data?
    private var listener: NWListener?

    init(port: UInt16, handler: @escaping @Sendable (Data) async -> Data?) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MCPServerError.invalidPort(port)
        }
        let params = NWParameters.tcp
        // 只监听回环地址：外部机器不可达
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        MixLog.info("[MCP] server 已监听 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        MixLog.info("[MCP] server 已停止")
    }

    // MARK: - 单连接处理（支持 keep-alive 串行多请求）

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()
        while true {
            if let request = HTTPRequestParser.parse(buffer: buffer) {
                buffer.removeFirst(request.consumedBytes)
                let response = await route(request)
                let sent = await send(response, over: connection)
                if !sent { break }
                continue
            }
            guard let chunk = await receiveChunk(connection), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if buffer.count > 4 * 1024 * 1024 { break }   // 防御：异常大请求直接断开
        }
        connection.cancel()
    }

    private func route(_ request: ParsedHTTPRequest) async -> Data {
        guard request.method == "POST", request.path == "/mcp" else {
            return Self.httpResponse(status: "404 Not Found", body: Data("not found".utf8), contentType: "text/plain")
        }
        guard let responseBody = await handler(request.body) else {
            // JSON-RPC notification：无应答体
            return Self.httpResponse(status: "202 Accepted", body: Data(), contentType: "application/json")
        }
        return Self.httpResponse(status: "200 OK", body: responseBody, contentType: "application/json")
    }

    private func receiveChunk(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if error != nil {
                    continuation.resume(returning: nil)
                } else if isComplete && (data?.isEmpty ?? true) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private static func httpResponse(status: String, body: Data, contentType: String) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

enum MCPServerError: Error, LocalizedError {
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let p): return "非法端口号：\(p)"
        }
    }
}
