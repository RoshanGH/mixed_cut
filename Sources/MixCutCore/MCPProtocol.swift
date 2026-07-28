import Foundation

/// JSON-RPC 请求 id：MCP 允许数字或字符串两种
public enum MCPRequestID: Equatable, Sendable {
    case number(Int)
    case string(String)

    var jsonValue: Any {
        switch self {
        case .number(let n): return n
        case .string(let s): return s
        }
    }
}

/// 解析后的 MCP 入站消息
public enum MCPIncoming: Equatable, Sendable {
    case initialize(id: MCPRequestID)
    /// 所有 notifications/*（无 id、无需应答）统一归入此 case
    case initializedNotification
    case ping(id: MCPRequestID)
    case toolsList(id: MCPRequestID)
    case toolsCall(id: MCPRequestID, name: String, argumentsData: Data)
    case invalid(id: MCPRequestID?, code: Int, message: String)
}

/// MCP 工具定义。inputSchema 以 JSON 文本携带，编码 tools/list 时展开为对象。
public struct MCPToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

/// MCP Streamable HTTP 的 JSON-RPC 解析与编码（纯函数，无网络依赖）
public enum MCPProtocol {
    public static let protocolVersion = "2025-06-18"

    // MARK: - 解析

    public static func parse(_ body: Data) -> MCPIncoming {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .invalid(id: nil, code: -32700, message: "JSON 解析失败")
        }
        let id = requestID(from: obj["id"])
        guard (obj["jsonrpc"] as? String) == "2.0", let method = obj["method"] as? String else {
            return .invalid(id: id, code: -32600, message: "无效的 JSON-RPC 请求")
        }
        if method.hasPrefix("notifications/") { return .initializedNotification }
        guard let id else {
            return .invalid(id: nil, code: -32600, message: "无效的 JSON-RPC 请求")
        }
        switch method {
        case "initialize": return .initialize(id: id)
        case "ping": return .ping(id: id)
        case "tools/list": return .toolsList(id: id)
        case "tools/call":
            guard let params = obj["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return .invalid(id: id, code: -32602, message: "tools/call 缺少 name 参数")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
            return .toolsCall(id: id, name: name, argumentsData: argsData)
        default:
            return .invalid(id: id, code: -32601, message: "不支持的方法：\(method)")
        }
    }

    private static func requestID(from value: Any?) -> MCPRequestID? {
        if let n = value as? Int { return .number(n) }
        if let s = value as? String { return .string(s) }
        return nil
    }

    // MARK: - 编码

    public static func initializeResponse(id: MCPRequestID, serverName: String, serverVersion: String) -> Data {
        envelope(id: id, result: [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": serverName, "version": serverVersion],
        ])
    }

    public static func pingResponse(id: MCPRequestID) -> Data {
        envelope(id: id, result: [String: Any]())
    }

    public static func toolsListResponse(id: MCPRequestID, tools: [MCPToolDefinition]) -> Data {
        let toolObjects: [[String: Any]] = tools.map { tool in
            let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)))
                as? [String: Any] ?? [:]
            return ["name": tool.name, "description": tool.description, "inputSchema": schema]
        }
        return envelope(id: id, result: ["tools": toolObjects])
    }

    public static func toolCallResponse(id: MCPRequestID, resultJSON: String, isError: Bool) -> Data {
        envelope(id: id, result: [
            "content": [["type": "text", "text": resultJSON]],
            "isError": isError,
        ])
    }

    public static func errorResponse(id: MCPRequestID?, code: Int, message: String) -> Data {
        let obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id?.jsonValue ?? NSNull(),
            "error": ["code": code, "message": message],
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private static func envelope(id: MCPRequestID, result: [String: Any]) -> Data {
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id.jsonValue, "result": result]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
