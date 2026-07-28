import Foundation
import Testing
@testable import MixCutCore

@Suite("MCPProtocol 解析")
struct MCPProtocolParseTests {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    @Test("解析 initialize")
    func parseInitialize() {
        let incoming = MCPProtocol.parse(body(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        #expect(incoming == .initialize(id: .number(1)))
    }

    @Test("解析 tools/list，字符串 id")
    func parseToolsListStringID() {
        let incoming = MCPProtocol.parse(body(#"{"jsonrpc":"2.0","id":"a1","method":"tools/list"}"#))
        #expect(incoming == .toolsList(id: .string("a1")))
    }

    @Test("解析 tools/call 提取 name 与 arguments")
    func parseToolsCall() throws {
        let incoming = MCPProtocol.parse(body(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_project","arguments":{"project_id":"abc"}}}"#))
        guard case .toolsCall(let id, let name, let argsData) = incoming else {
            Issue.record("应解析为 toolsCall，实际 \(incoming)"); return
        }
        #expect(id == .number(2))
        #expect(name == "get_project")
        let args = try JSONSerialization.jsonObject(with: argsData) as? [String: String]
        #expect(args == ["project_id": "abc"])
    }

    @Test("tools/call 缺 name 报 -32602")
    func parseToolsCallMissingName() {
        let incoming = MCPProtocol.parse(body(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{}}"#))
        #expect(incoming == .invalid(id: .number(3), code: -32602, message: "tools/call 缺少 name 参数"))
    }

    @Test("notifications/initialized 无需应答")
    func parseInitializedNotification() {
        let incoming = MCPProtocol.parse(body(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        #expect(incoming == .initializedNotification)
    }

    @Test("其它 notifications/* 一律按无需应答处理")
    func parseOtherNotification() {
        let incoming = MCPProtocol.parse(body(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#))
        #expect(incoming == .initializedNotification)
    }

    @Test("非法 JSON 报 -32700")
    func parseGarbage() {
        let incoming = MCPProtocol.parse(body("not json"))
        #expect(incoming == .invalid(id: nil, code: -32700, message: "JSON 解析失败"))
    }

    @Test("缺 method 报 -32600")
    func parseNoMethod() {
        let incoming = MCPProtocol.parse(body(#"{"jsonrpc":"2.0","id":9}"#))
        #expect(incoming == .invalid(id: .number(9), code: -32600, message: "无效的 JSON-RPC 请求"))
    }

    @Test("未知方法报 -32601")
    func parseUnknownMethod() {
        let incoming = MCPProtocol.parse(body(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#))
        #expect(incoming == .invalid(id: .number(4), code: -32601, message: "不支持的方法：resources/list"))
    }

    @Test("ping")
    func parsePing() {
        #expect(MCPProtocol.parse(body(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)) == .ping(id: .number(7)))
    }
}

@Suite("MCPProtocol 编码")
struct MCPProtocolEncodeTests {
    private func decode(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("initialize 响应结构")
    func initializeResponse() throws {
        let data = MCPProtocol.initializeResponse(id: .number(1), serverName: "mixcut", serverVersion: "0.9.3")
        let obj = try decode(data)
        #expect(obj["jsonrpc"] as? String == "2.0")
        #expect(obj["id"] as? Int == 1)
        let result = try #require(obj["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "mixcut")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test("tools/list 响应展开 inputSchema")
    func toolsListResponse() throws {
        let tool = MCPToolDefinition(
            name: "list_projects", description: "列出项目",
            inputSchemaJSON: #"{"type":"object","properties":{}}"#)
        let obj = try decode(MCPProtocol.toolsListResponse(id: .number(2), tools: [tool]))
        let result = try #require(obj["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "list_projects")
        let schema = try #require(tools[0]["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
    }

    @Test("tools/call 结果包装成 text content")
    func toolCallResponse() throws {
        let obj = try decode(MCPProtocol.toolCallResponse(id: .string("x"), resultJSON: #"{"ok":true}"#, isError: false))
        #expect(obj["id"] as? String == "x")
        let result = try #require(obj["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == #"{"ok":true}"#)
    }

    @Test("错误响应；id 为空时编码为 null")
    func errorResponse() throws {
        let obj = try decode(MCPProtocol.errorResponse(id: nil, code: -32700, message: "JSON 解析失败"))
        #expect(obj["id"] is NSNull)
        let err = try #require(obj["error"] as? [String: Any])
        #expect(err["code"] as? Int == -32700)
        #expect(err["message"] as? String == "JSON 解析失败")
    }

    @Test("ping 响应为空 result")
    func pingResponse() throws {
        let obj = try decode(MCPProtocol.pingResponse(id: .number(7)))
        #expect((obj["result"] as? [String: Any])?.isEmpty == true)
    }
}
