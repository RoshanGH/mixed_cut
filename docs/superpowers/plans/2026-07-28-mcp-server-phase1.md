# MCP Server 第一阶段实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 MixCut app 内嵌一个零依赖的本地 MCP server（127.0.0.1:8787），让 Claude Code 能新建项目、批量导入视频、监控 8 步流水线、重试失败、移除视频。

**Architecture:** 协议解析/编码（JSON-RPC + HTTP 请求解析 + 工具目录）为纯函数，放 `Sources/MixCutCore/` TDD 单测；NWListener 传输壳、@MainActor 工具处理器、内存任务注册表放 app target `MixCut/Services/MCP/`。MCP 持有 headless `ImportViewModel` 实例复用现有导入编排，共用 mainContext。

**Tech Stack:** Swift 5.10 / SwiftData / Network.framework / Swift Testing。零第三方依赖。

**Spec:** `docs/superpowers/specs/2026-07-28-mcp-server-phase1-design.md`

## Global Constraints

- 零第三方 SPM 依赖；MixCutCore 内不得 import SwiftData/SwiftUI/Network
- server 只绑定 `127.0.0.1`，默认端口 `8787`，UserDefaults 键 `agentServerEnabled`（默认 true）/ `agentServerPort`
- 对现有 UI 行为零破坏：`importVideos` 改动必须 `@discardableResult` 纯加法；`deleteVideo` 的撤销浮条路径行为不变
- 不新建 ModelContext，一律用 `container.mainContext`
- 同一时间只允许一个 agent job 运行（`JOB_ALREADY_RUNNING`）
- 工具返回 JSON 字段英文命名，错误 message 中文
- 编译用 Xcode：`xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`；Core 单测用 `swift test`
- commit message 中文、conventional commits、无 attribution

---

### Task 1: MixCutCore — MCPRequestID / MCPIncoming / MCPProtocol（JSON-RPC 解析与编码）

**Files:**
- Create: `Sources/MixCutCore/MCPProtocol.swift`
- Test: `Tests/MixCutCoreTests/MCPProtocolTests.swift`

**Interfaces:**
- Produces（后续 Task 6/7 依赖）:
  - `enum MCPRequestID: Equatable, Sendable { case number(Int); case string(String) }`
  - `enum MCPIncoming: Equatable, Sendable { case initialize(id:), initializedNotification, ping(id:), toolsList(id:), toolsCall(id:name:argumentsData:), invalid(id:code:message:) }`
  - `struct MCPToolDefinition: Sendable { let name, description, inputSchemaJSON: String }`
  - `enum MCPProtocol` 静态方法：`parse(_ body: Data) -> MCPIncoming`、`initializeResponse(id:serverName:serverVersion:) -> Data`、`pingResponse(id:) -> Data`、`toolsListResponse(id:tools:) -> Data`、`toolCallResponse(id:resultJSON:isError:) -> Data`、`errorResponse(id:code:message:) -> Data`

- [ ] **Step 1: 写失败测试**（`Tests/MixCutCoreTests/MCPProtocolTests.swift`）

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MCPProtocol 2>&1 | tail -5`
Expected: 编译失败（`MCPProtocol` 未定义）

- [ ] **Step 3: 实现 `Sources/MixCutCore/MCPProtocol.swift`**

```swift
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter MCPProtocol 2>&1 | tail -5`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MixCutCore/MCPProtocol.swift Tests/MixCutCoreTests/MCPProtocolTests.swift
git commit -m "feat: MCP JSON-RPC 协议解析与编码（MixCutCore 纯函数，TDD）"
```

---

### Task 2: MixCutCore — HTTPRequestParser（极简 HTTP/1.1 请求解析）

**Files:**
- Create: `Sources/MixCutCore/HTTPRequestParser.swift`
- Test: `Tests/MixCutCoreTests/HTTPRequestParserTests.swift`

**Interfaces:**
- Produces（Task 6 依赖）:
  - `struct ParsedHTTPRequest: Equatable, Sendable { let method, path: String; let body: Data; let consumedBytes: Int }`
  - `enum HTTPRequestParser { static func parse(buffer: Data) -> ParsedHTTPRequest? }` — 缓冲区不含完整请求时返回 nil（继续收包）

- [ ] **Step 1: 写失败测试**（`Tests/MixCutCoreTests/HTTPRequestParserTests.swift`）

```swift
import Foundation
import Testing
@testable import MixCutCore

@Suite("HTTPRequestParser")
struct HTTPRequestParserTests {
    private func request(_ s: String) -> Data { Data(s.utf8) }

    @Test("完整 POST 带 body")
    func parsePostWithBody() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"jsonrpc\":1}"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/mcp")
        #expect(String(data: parsed.body, encoding: .utf8) == "{\"jsonrpc\":1}")
        #expect(parsed.consumedBytes == raw.utf8.count)
    }

    @Test("头部不完整返回 nil")
    func incompleteHeaders() {
        #expect(HTTPRequestParser.parse(buffer: request("POST /mcp HTTP/1.1\r\nContent-Le")) == nil)
    }

    @Test("body 未收全返回 nil")
    func incompleteBody() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"partial\":"
        #expect(HTTPRequestParser.parse(buffer: request(raw)) == nil)
    }

    @Test("无 Content-Length 视为空 body（GET 探活）")
    func getWithoutContentLength() throws {
        let raw = "GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.method == "GET")
        #expect(parsed.path == "/health")
        #expect(parsed.body.isEmpty)
    }

    @Test("Content-Length 大小写不敏感")
    func caseInsensitiveHeader() throws {
        let raw = "POST /mcp HTTP/1.1\r\ncontent-length: 2\r\n\r\nhi"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(String(data: parsed.body, encoding: .utf8) == "hi")
    }

    @Test("consumedBytes 支持同一缓冲区多请求（keep-alive）")
    func pipelinedRequests() throws {
        let first = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\nab"
        let second = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\ncd"
        var buffer = request(first + second)
        let parsed1 = try #require(HTTPRequestParser.parse(buffer: buffer))
        #expect(String(data: parsed1.body, encoding: .utf8) == "ab")
        buffer.removeFirst(parsed1.consumedBytes)
        let parsed2 = try #require(HTTPRequestParser.parse(buffer: buffer))
        #expect(String(data: parsed2.body, encoding: .utf8) == "cd")
    }

    @Test("畸形请求行返回 nil")
    func malformedRequestLine() {
        #expect(HTTPRequestParser.parse(buffer: request("GARBAGE\r\n\r\n")) == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter HTTPRequestParser 2>&1 | tail -5`
Expected: 编译失败（`HTTPRequestParser` 未定义）

- [ ] **Step 3: 实现 `Sources/MixCutCore/HTTPRequestParser.swift`**

```swift
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter HTTPRequestParser 2>&1 | tail -5`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MixCutCore/HTTPRequestParser.swift Tests/MixCutCoreTests/HTTPRequestParserTests.swift
git commit -m "feat: 极简 HTTP/1.1 请求解析器（支撑内嵌 MCP server，TDD）"
```

---

### Task 3: MixCutCore — AgentToolCatalog（9 个工具定义）+ AgentJSON（结果/错误编码）

**Files:**
- Create: `Sources/MixCutCore/AgentToolCatalog.swift`
- Test: `Tests/MixCutCoreTests/AgentToolCatalogTests.swift`

**Interfaces:**
- Produces（Task 7 依赖）:
  - `AgentToolCatalog.all: [MCPToolDefinition]` — 9 个工具
  - `enum AgentToolErrorCode: String, Sendable`（6 个错误码）
  - `enum AgentJSON { static func encode(_ object: Any) -> String; static func error(code:message:) -> String }`

- [ ] **Step 1: 写失败测试**（`Tests/MixCutCoreTests/AgentToolCatalogTests.swift`）

```swift
import Foundation
import Testing
@testable import MixCutCore

@Suite("AgentToolCatalog")
struct AgentToolCatalogTests {
    @Test("9 个工具且命名齐全")
    func allTools() {
        let names = AgentToolCatalog.all.map(\.name)
        #expect(names == [
            "list_projects", "get_project", "list_segments", "get_job",
            "create_project", "import_videos", "retry_analysis", "retry_asr", "remove_video",
        ])
    }

    @Test("每个工具的 inputSchema 都是合法 JSON object")
    func schemasAreValidJSON() throws {
        for tool in AgentToolCatalog.all {
            let obj = try JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any]
            #expect(obj?["type"] as? String == "object", "\(tool.name) schema 非法")
            #expect(!tool.description.isEmpty)
        }
    }

    @Test("import_videos schema 声明必填参数")
    func importVideosSchema() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "import_videos" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let required = try #require(obj["required"] as? [String])
        #expect(Set(required) == ["project_id", "paths"])
    }

    @Test("AgentJSON.error 输出结构化错误")
    func errorJSON() throws {
        let json = AgentJSON.error(code: .projectNotFound, message: "找不到项目 x")
        let obj = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["code"] as? String == "PROJECT_NOT_FOUND")
        #expect(obj["message"] as? String == "找不到项目 x")
    }

    @Test("AgentJSON.encode 稳定输出（sortedKeys）")
    func encodeSorted() {
        let json = AgentJSON.encode(["b": 1, "a": 2])
        #expect(json == #"{"a":2,"b":1}"#)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AgentToolCatalog 2>&1 | tail -5`
Expected: 编译失败（`AgentToolCatalog` 未定义）

- [ ] **Step 3: 实现 `Sources/MixCutCore/AgentToolCatalog.swift`**

```swift
import Foundation

/// Agent 工具错误码（工具层结构化错误，区别于 JSON-RPC 协议层错误）
public enum AgentToolErrorCode: String, Sendable {
    case invalidArgument = "INVALID_ARGUMENT"
    case projectNotFound = "PROJECT_NOT_FOUND"
    case videoNotFound = "VIDEO_NOT_FOUND"
    case jobNotFound = "JOB_NOT_FOUND"
    case fileNotFound = "FILE_NOT_FOUND"
    case jobAlreadyRunning = "JOB_ALREADY_RUNNING"
}

/// 工具结果/错误的 JSON 文本编码
public enum AgentJSON {
    public static func encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return #"{"code":"INVALID_ARGUMENT","message":"内部错误：结果无法编码为 JSON"}"#
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func error(code: AgentToolErrorCode, message: String) -> String {
        encode(["code": code.rawValue, "message": message])
    }
}

/// 第一阶段的 9 个 MCP 工具定义（实现在 app target 的 MCPToolHandlers）
public enum AgentToolCatalog {
    public static let all: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_projects",
            description: "列出所有项目及其状态、视频数、分镜数、方案数",
            inputSchemaJSON: #"{"type":"object","properties":{},"required":[]}"#),
        MCPToolDefinition(
            name: "get_project",
            description: "获取项目详情，含每个视频的处理状态、时长、失败原因、分镜数",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"}},"required":["project_id"]}"#),
        MCPToolDefinition(
            name: "list_segments",
            description: "列出分镜（台词、帧范围、语义类型、位置、质量分）。project_id 与 video_id 二选一，同时提供报错",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_id 二选一）"},"video_id":{"type":"string","description":"视频 UUID（与 project_id 二选一）"},"semantic_type":{"type":"string","description":"可选，按语义类型过滤，如 痛点/行动号召"},"position_type":{"type":"string","description":"可选，按位置过滤：开头/中间/结尾"}},"required":[]}"#),
        MCPToolDefinition(
            name: "get_job",
            description: "查询异步任务状态与该项目所有视频的实时流水线进度",
            inputSchemaJSON: #"{"type":"object","properties":{"job_id":{"type":"string","description":"任务 UUID"}},"required":["job_id"]}"#),
        MCPToolDefinition(
            name: "create_project",
            description: "新建项目",
            inputSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"项目名称"}},"required":["name"]}"#),
        MCPToolDefinition(
            name: "import_videos",
            description: "把本地视频文件导入项目并启动完整分析流水线（场景检测→ASR→AI 语义分析→边界优化）。立即返回 job_id，用 get_job 轮询进度",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"},"paths":{"type":"array","items":{"type":"string"},"description":"视频文件绝对路径数组"}},"required":["project_id","paths"]}"#),
        MCPToolDefinition(
            name: "retry_analysis",
            description: "对失败的视频重试 AI 语义分析。返回 job_id",
            inputSchemaJSON: #"{"type":"object","properties":{"video_id":{"type":"string","description":"视频 UUID"}},"required":["video_id"]}"#),
        MCPToolDefinition(
            name: "retry_asr",
            description: "对识别异常的视频重跑语音识别（会连带重做 AI 分析并重建分镜）。返回 job_id",
            inputSchemaJSON: #"{"type":"object","properties":{"video_id":{"type":"string","description":"视频 UUID"}},"required":["video_id"]}"#),
        MCPToolDefinition(
            name: "remove_video",
            description: "从项目移除视频（立即生效，无撤销）。若视频不被其它项目引用则连分镜记录一起删除",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"},"video_id":{"type":"string","description":"视频 UUID"}},"required":["project_id","video_id"]}"#),
    ]
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AgentToolCatalog 2>&1 | tail -5`
Expected: 全部 PASS

- [ ] **Step 5: 全量跑一遍 Core 测试防回归**

Run: `swift test 2>&1 | tail -3`
Expected: 全部 PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/MixCutCore/AgentToolCatalog.swift Tests/MixCutCoreTests/AgentToolCatalogTests.swift
git commit -m "feat: Agent 工具目录（9 个工具定义）与结构化错误编码（TDD）"
```

---

### Task 4: App — ImportViewModel 加法改动（ImportReport + 立即删除路径）

**Files:**
- Modify: `MixCut/ViewModels/ImportViewModel.swift`

**Interfaces:**
- Produces（Task 5/7 依赖）:
  - `struct ImportReport: Sendable`（定义见下）
  - `@discardableResult func importVideos(urls: [URL], to project: Project) async -> ImportReport`
  - `@discardableResult func removeVideoImmediately(_ video: Video, from project: Project) -> Bool`（true = 视频已无引用、全局记录被删）
- 不变量：UI 调用点（ImportView 等）零修改；`deleteVideo` 的撤销浮条行为不变

- [ ] **Step 1: 在 `ImportViewModel.swift` 顶部（`ImportPhase` 枚举之后）加 `ImportReport`**

```swift
/// 一次导入调用的结构化结果（给 Agent/MCP 用；UI 路径忽略返回值）
struct ImportReport: Sendable {
    var importedVideoIDs: [UUID] = []
    var importedNames: [String] = []
    var linkedExistingNames: [String] = []
    var skippedDuplicateNames: [String] = []
    var failed: [FailedItem] = []
    /// 整体中止原因（全部重复 / 磁盘不足 / 上下文缺失 / 用户停止），nil 表示正常走完
    var abortMessage: String?

    struct FailedItem: Sendable {
        let name: String
        let reason: String
    }
}
```

- [ ] **Step 2: 改 `importVideos` 收集并返回 report（只加行，不删行为）**

签名改为 `@discardableResult func importVideos(urls: [URL], to project: Project) async -> ImportReport`，函数开头加 `var report = ImportReport()`，然后在既有分支就地补：
- 去重循环里 `skippedNames.append(...)` 后加 `report.skippedDuplicateNames.append(url.lastPathComponent)`
- 「全部重复」early return 前加 `report.abortMessage = errorMessage`，`return` 改 `return report`
- 磁盘不足 early return 前加 `report.abortMessage = errorMessage`，`return` 改 `return report`
- `guard let context = modelContext else { return }` 改为 `else { report.abortMessage = "内部错误：modelContext 未注入"; return report }`
- 阶段 1 成功分支：`needsAnalysis` 为 true 时加 `report.importedVideoIDs.append(video.id); report.importedNames.append(video.name)`；false 分支加 `report.linkedExistingNames.append(video.name)`
- 阶段 1 catch 分支加 `report.failed.append(.init(name: url.lastPathComponent, reason: FriendlyError.reason(for: error)))`
- 两处 `finishAsCancelled(...); return` 改为 `finishAsCancelled(...); report.abortMessage = "用户停止导入"; return report`
- 函数末尾 `return report`

注意：分析阶段的失败**不进 report**（那是 `video.status == .failed` + `errorMessage` 的职责，get_job 实时读）。

- [ ] **Step 3: 抽取 `deleteVideo` 的 commit 闭包为共享方法，并加 `removeVideoImmediately`**

把 `deleteVideo` 中 `commit:` 闭包体（删 pv → 判断无引用 → 删 segment/schemeSegment/video）抽成：

```swift
    /// 真删除：删关联 pv；若视频已无任何项目引用，连分镜与视频记录一起删（磁盘文件交孤儿 GC）
    /// 返回 true 表示视频全局记录已删除
    @discardableResult
    private func commitDelete(video: Video, pendingPVs: [ProjectVideo]) -> Bool {
        guard let context = modelContext else { return false }
        for pv in pendingPVs { context.delete(pv) }
        context.safeSave()
        guard video.projectVideos.isEmpty else {
            MixLog.info(" 视频仍被其它项目引用，仅解除关联: \(video.name)")
            return false
        }
        let segmentsToDelete = Array(video.segments)
        for segment in segmentsToDelete {
            for ss in Array(segment.schemeSegments) { context.delete(ss) }
            context.delete(segment)
        }
        context.delete(video)
        context.safeSave()
        MixLog.info(" 视频无引用，已删除记录: \(video.name)")
        return true
    }
```

`deleteVideo` 的 `commit:` 闭包改为一行：`self?.commitDelete(video: video, pendingPVs: pvsToHide)`（undo 闭包与其余逻辑不动）。

新增 Agent 立即删除入口（不走 PendingDeletionCenter 浮条）：

```swift
    /// Agent 立即删除路径：与 deleteVideo 等价但立即生效、无撤销
    @discardableResult
    func removeVideoImmediately(_ video: Video, from project: Project) -> Bool {
        guard modelContext != nil else { return false }
        cancelledVideoIDs.insert(video.id)
        let pvsToRemove = project.projectVideos.filter { $0.video?.id == video.id }
        let pvIDs = Set(pvsToRemove.map(\.id))
        project.projectVideos.removeAll { pvIDs.contains($0.id) }
        return commitDelete(video: video, pendingPVs: pvsToRemove)
    }
```

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`（`@discardableResult` 保证 ImportView 等调用点无警告无改动）

- [ ] **Step 5: Commit**

```bash
git add MixCut/ViewModels/ImportViewModel.swift
git commit -m "feat: importVideos 返回结构化 ImportReport；抽取 commitDelete 并新增立即删除路径（Agent 用）"
```

---

### Task 5: App — AgentJobRegistry（内存任务注册表）

**Files:**
- Create: `MixCut/Services/MCP/AgentJobRegistry.swift`

**Interfaces:**
- Consumes: `ImportReport`（Task 4）
- Produces（Task 7 依赖）:
  - `@MainActor final class AgentJobRegistry`
  - `begin(kind:projectID:) -> AgentJob`、`finish(_:report:)`、`fail(_:message:)`、`job(_:) -> AgentJob?`、`activeJob: AgentJob?`

- [ ] **Step 1: 实现 `MixCut/Services/MCP/AgentJobRegistry.swift`**

```swift
import Foundation

/// Agent 发起的异步任务（导入/重试）。内存态，app 重启即失效（启动自愈由
/// MixCutApp.resetStaleAnalyzingStatus 兜底，Agent 改查 get_project 即可）。
struct AgentJob: Sendable {
    enum Kind: String, Sendable {
        case importVideos = "import_videos"
        case retryAnalysis = "retry_analysis"
        case retryASR = "retry_asr"
    }

    enum State: String, Sendable {
        case running
        case completed
        case failed
    }

    let id: UUID
    let kind: Kind
    let projectID: UUID
    let startedAt: Date
    var finishedAt: Date?
    var state: State
    var report: ImportReport?
    var failureMessage: String?
}

/// Agent 任务注册表：同一时间只允许一个任务运行（与 UI 串行导入行为一致，
/// 规避共享 mainContext 的并发踩踏）
@MainActor
final class AgentJobRegistry {
    private(set) var jobs: [UUID: AgentJob] = [:]

    var activeJob: AgentJob? {
        jobs.values.first { $0.state == .running }
    }

    func begin(kind: AgentJob.Kind, projectID: UUID) -> AgentJob {
        let job = AgentJob(
            id: UUID(), kind: kind, projectID: projectID,
            startedAt: Date(), finishedAt: nil, state: .running,
            report: nil, failureMessage: nil)
        jobs[job.id] = job
        return job
    }

    func finish(_ id: UUID, report: ImportReport?) {
        guard var job = jobs[id] else { return }
        job.state = .completed
        job.finishedAt = Date()
        job.report = report
        jobs[id] = job
    }

    func fail(_ id: UUID, message: String) {
        guard var job = jobs[id] else { return }
        job.state = .failed
        job.finishedAt = Date()
        job.failureMessage = message
        jobs[id] = job
    }

    func job(_ id: UUID) -> AgentJob? { jobs[id] }
}
```

- [ ] **Step 2: 把新文件加进 Xcode 工程并编译**

新文件在 `MixCut/` 目录树内。先确认工程是否用 fileSystemSynchronizedGroups（Xcode 16 自动收录）：
`grep -c "fileSystemSynchronizedGroups\|PBXFileSystemSynchronizedRootGroup" MixCut.xcodeproj/project.pbxproj`。
若 >0 则新文件自动入 target；若 =0，需要用 `ruby` 或手工把文件引用加进 `project.pbxproj`（参照现有 `MixCut/Services/BGM/BGMLibraryStore.swift` 的三处条目：PBXBuildFile、PBXFileReference、group children + Sources build phase）。

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MixCut/Services/MCP/AgentJobRegistry.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat: Agent 任务注册表（内存态，单任务并发约束）"
```

---

### Task 6: App — MCPServer（NWListener HTTP 传输壳）

**Files:**
- Create: `MixCut/Services/MCP/MCPServer.swift`

**Interfaces:**
- Consumes: `HTTPRequestParser.parse(buffer:)`（Task 2）
- Produces（Task 7 依赖）:
  - `actor MCPServer { init(port: UInt16, handler: @escaping @Sendable (Data) async -> Data?); func start() throws; func stop() }`
  - handler 入参为 JSON-RPC 请求 body，返回 nil 表示无需应答（notification → HTTP 202）

- [ ] **Step 1: 实现 `MixCut/Services/MCP/MCPServer.swift`**

```swift
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
                if error != nil || isComplete && (data?.isEmpty ?? true) {
                    continuation.resume(returning: data)
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
```

注意：若项目中 `MixLog` 不存在该用法，参照 `ImportViewModel.swift` 里 `MixLog.info(...)` 的现有调用方式。

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MixCut/Services/MCP/MCPServer.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat: 内嵌 MCP server 传输壳（NWListener，仅回环地址，keep-alive）"
```

---

### Task 7: App — MCPToolHandlers（9 工具实现）+ AgentGateway（装配与生命周期）

**Files:**
- Create: `MixCut/Services/MCP/MCPToolHandlers.swift`
- Create: `MixCut/Services/MCP/AgentGateway.swift`

**Interfaces:**
- Consumes: `MCPProtocol`/`AgentToolCatalog`/`AgentJSON`（Task 1/3）、`ImportReport`/`removeVideoImmediately`（Task 4）、`AgentJobRegistry`（Task 5）、`MCPServer`（Task 6）
- Produces（Task 8 依赖）:
  - `AgentGateway.shared`（@MainActor 单例）：`configure(container: ModelContainer)`、`restartFromSettings()`
  - UserDefaults 键常量：`AgentGateway.enabledKey == "agentServerEnabled"`、`AgentGateway.portKey == "agentServerPort"`、`AgentGateway.defaultPort: UInt16 == 8787`

- [ ] **Step 1: 实现 `MixCut/Services/MCP/MCPToolHandlers.swift`**

```swift
import Foundation
import SwiftData

/// MCP 工具实现层：@MainActor 上读写 mainContext，返回 JSON 文本
@MainActor
final class MCPToolHandlers {
    struct Outcome: Sendable {
        let json: String
        let isError: Bool
    }

    private struct ToolFailure: Error {
        let code: AgentToolErrorCode
        let message: String
    }

    private let context: ModelContext
    private let importVM: ImportViewModel
    private let jobs: AgentJobRegistry

    init(context: ModelContext, importVM: ImportViewModel, jobs: AgentJobRegistry) {
        self.context = context
        self.importVM = importVM
        self.jobs = jobs
    }

    func call(name: String, argumentsData: Data) async -> Outcome {
        do {
            switch name {
            case "list_projects": return try listProjects()
            case "get_project": return try getProject(argumentsData)
            case "list_segments": return try listSegments(argumentsData)
            case "get_job": return try getJob(argumentsData)
            case "create_project": return try createProject(argumentsData)
            case "import_videos": return try importVideos(argumentsData)
            case "retry_analysis": return try retryPipeline(argumentsData, kind: .retryAnalysis)
            case "retry_asr": return try retryPipeline(argumentsData, kind: .retryASR)
            case "remove_video": return try removeVideo(argumentsData)
            default:
                return failure(.invalidArgument, "未知工具：\(name)")
            }
        } catch let failure as ToolFailure {
            return self.failure(failure.code, failure.message)
        } catch let decoding as DecodingError {
            return failure(.invalidArgument, "参数解析失败：\(decoding)")
        } catch {
            return failure(.invalidArgument, FriendlyError.reason(for: error))
        }
    }

    // MARK: - 只读工具

    private func listProjects() throws -> Outcome {
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let projects = (try? context.fetch(descriptor)) ?? []
        let items: [[String: Any]] = projects.map { p in
            [
                "id": p.id.uuidString,
                "name": p.name,
                "status": p.status.rawValue,
                "video_count": p.videoCount,
                "segment_count": p.segmentCount,
                "scheme_count": p.schemeCount,
                "updated_at": Self.iso(p.updatedAt),
            ]
        }
        return success(["projects": items])
    }

    private struct GetProjectArgs: Decodable { let project_id: String }

    private func getProject(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(GetProjectArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        return success([
            "id": project.id.uuidString,
            "name": project.name,
            "status": project.status.rawValue,
            "created_at": Self.iso(project.createdAt),
            "updated_at": Self.iso(project.updatedAt),
            "videos": project.videos.map(Self.videoSummary),
        ])
    }

    private struct ListSegmentsArgs: Decodable {
        let project_id: String?
        let video_id: String?
        let semantic_type: String?
        let position_type: String?
    }

    private func listSegments(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(ListSegmentsArgs.self, from: data)
        let videos: [Video]
        switch (args.project_id, args.video_id) {
        case (.some, .some):
            throw ToolFailure(code: .invalidArgument, message: "project_id 与 video_id 只能提供一个")
        case (.some(let pid), .none):
            videos = try fetchProject(pid).videos
        case (.none, .some(let vid)):
            videos = [try fetchVideo(vid)]
        case (.none, .none):
            throw ToolFailure(code: .invalidArgument, message: "必须提供 project_id 或 video_id 之一")
        }
        var items: [[String: Any]] = []
        for video in videos {
            let sorted = video.segments.sorted { $0.startFrame < $1.startFrame }
            for seg in sorted {
                let types = seg.semanticTypes.map(\.rawValue)
                if let filter = args.semantic_type, !types.contains(filter) { continue }
                if let filter = args.position_type, seg.positionType.rawValue != filter { continue }
                items.append([
                    "id": seg.id.uuidString,
                    "segment_index": seg.segmentIndex,
                    "video_id": video.id.uuidString,
                    "video_name": video.name,
                    "start_frame": seg.startFrame,
                    "end_frame": seg.endFrame,
                    "start_sec": seg.startTime,
                    "end_sec": seg.endTime,
                    "duration_sec": seg.duration,
                    "text": seg.text,
                    "semantic_types": types,
                    "position_type": seg.positionType.rawValue,
                    "confidence": seg.confidence,
                    "quality_score": seg.qualityScore,
                ])
            }
        }
        return success(["segments": items, "count": items.count])
    }

    private struct GetJobArgs: Decodable { let job_id: String }

    private func getJob(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(GetJobArgs.self, from: data)
        guard let jobID = UUID(uuidString: args.job_id) else {
            throw ToolFailure(code: .invalidArgument, message: "job_id 不是合法 UUID")
        }
        guard let job = jobs.job(jobID) else {
            throw ToolFailure(code: .jobNotFound, message: "找不到任务 \(args.job_id)（app 重启后任务会丢失，请改用 get_project 查看视频实时状态）")
        }
        var payload: [String: Any] = [
            "id": job.id.uuidString,
            "kind": job.kind.rawValue,
            "state": job.state.rawValue,
            "project_id": job.projectID.uuidString,
            "started_at": Self.iso(job.startedAt),
        ]
        if let finished = job.finishedAt { payload["finished_at"] = Self.iso(finished) }
        if let message = job.failureMessage { payload["failure_message"] = message }
        if let report = job.report {
            payload["report"] = [
                "imported": report.importedNames,
                "linked_existing": report.linkedExistingNames,
                "skipped_duplicates": report.skippedDuplicateNames,
                "failed": report.failed.map { ["name": $0.name, "reason": $0.reason] },
                "abort_message": report.abortMessage ?? NSNull(),
            ] as [String: Any]
        }
        // 项目内所有视频的实时流水线状态（直接读 SwiftData，非缓存）
        if let project = try? fetchProject(job.projectID.uuidString) {
            payload["videos"] = project.videos.map(Self.videoSummary)
        }
        return success(payload)
    }

    // MARK: - 写工具

    private struct CreateProjectArgs: Decodable { let name: String }

    private func createProject(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(CreateProjectArgs.self, from: data)
        let trimmed = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolFailure(code: .invalidArgument, message: "项目名称不能为空")
        }
        let project = Project(name: trimmed)
        context.insert(project)
        context.safeSave()
        return success(["id": project.id.uuidString, "name": project.name])
    }

    private struct ImportVideosArgs: Decodable {
        let project_id: String
        let paths: [String]
    }

    private func importVideos(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(ImportVideosArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        guard !args.paths.isEmpty else {
            throw ToolFailure(code: .invalidArgument, message: "paths 不能为空")
        }
        for path in args.paths {
            guard path.hasPrefix("/") else {
                throw ToolFailure(code: .invalidArgument, message: "必须是绝对路径：\(path)")
            }
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw ToolFailure(code: .fileNotFound, message: "文件不存在或不可读：\(path)")
            }
        }
        try ensureNoActiveJob()
        let job = jobs.begin(kind: .importVideos, projectID: project.id)
        let urls = args.paths.map { URL(fileURLWithPath: $0) }
        let vm = importVM
        let registry = jobs
        Task { @MainActor in
            let report = await vm.importVideos(urls: urls, to: project)
            registry.finish(job.id, report: report)
        }
        return success(["job_id": job.id.uuidString])
    }

    private struct RetryArgs: Decodable { let video_id: String }

    private func retryPipeline(_ data: Data, kind: AgentJob.Kind) throws -> Outcome {
        let args = try JSONDecoder().decode(RetryArgs.self, from: data)
        let video = try fetchVideo(args.video_id)
        guard let project = video.projectVideos.first?.project else {
            throw ToolFailure(code: .projectNotFound, message: "视频未关联任何项目，无法重试")
        }
        try ensureNoActiveJob()
        let job = jobs.begin(kind: kind, projectID: project.id)
        let vm = importVM
        let registry = jobs
        Task { @MainActor in
            if kind == .retryASR {
                await vm.retryASR(for: video, in: project)
            } else {
                await vm.retryAIAnalysis(for: video, in: project)
            }
            registry.finish(job.id, report: nil)
        }
        return success(["job_id": job.id.uuidString])
    }

    private struct RemoveVideoArgs: Decodable {
        let project_id: String
        let video_id: String
    }

    private func removeVideo(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(RemoveVideoArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        let video = try fetchVideo(args.video_id)
        guard project.videos.contains(where: { $0.id == video.id }) else {
            throw ToolFailure(code: .videoNotFound, message: "视频不在该项目中")
        }
        let deletedGlobally = importVM.removeVideoImmediately(video, from: project)
        return success(["removed": true, "video_deleted_globally": deletedGlobally])
    }

    // MARK: - 公共辅助

    private func ensureNoActiveJob() throws {
        if let active = jobs.activeJob {
            throw ToolFailure(
                code: .jobAlreadyRunning,
                message: "已有任务在运行（job_id: \(active.id.uuidString)），请等它完成后再发起")
        }
    }

    private func fetchProject(_ idString: String) throws -> Project {
        guard let uuid = UUID(uuidString: idString) else {
            throw ToolFailure(code: .invalidArgument, message: "project_id 不是合法 UUID：\(idString)")
        }
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == uuid })
        guard let project = try? context.fetch(descriptor).first else {
            throw ToolFailure(code: .projectNotFound, message: "找不到项目 \(idString)")
        }
        return project
    }

    private func fetchVideo(_ idString: String) throws -> Video {
        guard let uuid = UUID(uuidString: idString) else {
            throw ToolFailure(code: .invalidArgument, message: "video_id 不是合法 UUID：\(idString)")
        }
        let descriptor = FetchDescriptor<Video>(predicate: #Predicate { $0.id == uuid })
        guard let video = try? context.fetch(descriptor).first else {
            throw ToolFailure(code: .videoNotFound, message: "找不到视频 \(idString)")
        }
        return video
    }

    private static func videoSummary(_ video: Video) -> [String: Any] {
        [
            "id": video.id.uuidString,
            "name": video.name,
            "status": video.status.rawValue,
            "duration_sec": video.duration,
            "error_message": video.errorMessage ?? NSNull(),
            "segment_count": video.segments.count,
        ] as [String: Any]
    }

    private func success(_ object: [String: Any]) -> Outcome {
        Outcome(json: AgentJSON.encode(object), isError: false)
    }

    private func failure(_ code: AgentToolErrorCode, _ message: String) -> Outcome {
        Outcome(json: AgentJSON.error(code: code, message: message), isError: true)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
```

- [ ] **Step 2: 实现 `MixCut/Services/MCP/AgentGateway.swift`**

```swift
import Foundation
import SwiftData

/// Agent 接入的装配与生命周期管理：持有 server、工具处理器、headless 导入 VM
@MainActor
final class AgentGateway {
    static let shared = AgentGateway()

    static let enabledKey = "agentServerEnabled"
    static let portKey = "agentServerPort"
    static let defaultPort: UInt16 = 8787

    private var server: MCPServer?
    private var handlers: MCPToolHandlers?
    private let importVM = ImportViewModel()
    private let jobs = AgentJobRegistry()

    private init() {}

    static var configuredPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        guard stored > 0, stored <= 65535 else { return defaultPort }
        return UInt16(stored)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var registerCommand: String {
        "claude mcp add --transport http mixcut http://127.0.0.1:\(configuredPort)/mcp"
    }

    func configure(container: ModelContainer) {
        importVM.setModelContext(container.mainContext)
        handlers = MCPToolHandlers(context: container.mainContext, importVM: importVM, jobs: jobs)
        restartFromSettings()
    }

    /// 按当前 UserDefaults 设置重启 server（开关/端口变更后调用）
    func restartFromSettings() {
        guard let handlers else { return }
        let port = Self.configuredPort
        let enabled = Self.isEnabled
        let oldServer = server
        server = nil
        Task {
            await oldServer?.stop()
            guard enabled else { return }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            let newServer = MCPServer(port: port) { body in
                await Self.dispatch(body: body, handlers: handlers, serverVersion: version)
            }
            do {
                try await newServer.start()
                await MainActor.run { self.server = newServer }
            } catch {
                await MainActor.run {
                    ToastCenter.shared.show(
                        "Agent 服务启动失败：端口 \(port) 可能被占用，可在设置中修改",
                        icon: "antenna.radiowaves.left.and.right.slash", style: .error)
                }
            }
        }
    }

    /// JSON-RPC 分发：解析 → 路由 → 编码。返回 nil 表示 notification 无需应答。
    private static func dispatch(
        body: Data, handlers: MCPToolHandlers, serverVersion: String
    ) async -> Data? {
        switch MCPProtocol.parse(body) {
        case .initialize(let id):
            return MCPProtocol.initializeResponse(id: id, serverName: "mixcut", serverVersion: serverVersion)
        case .initializedNotification:
            return nil
        case .ping(let id):
            return MCPProtocol.pingResponse(id: id)
        case .toolsList(let id):
            return MCPProtocol.toolsListResponse(id: id, tools: AgentToolCatalog.all)
        case .toolsCall(let id, let name, let argumentsData):
            let outcome = await handlers.call(name: name, argumentsData: argumentsData)
            return MCPProtocol.toolCallResponse(id: id, resultJSON: outcome.json, isError: outcome.isError)
        case .invalid(let id, let code, let message):
            return MCPProtocol.errorResponse(id: id, code: code, message: message)
        }
    }
}
```

注意：`ToastCenter.show` 的参数签名以 `MixCut/Views/Shared/Toast.swift` 实际定义为准（style 枚举名可能是 `.error/.warning`，先读文件确认）。

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add MixCut/Services/MCP/MCPToolHandlers.swift MixCut/Services/MCP/AgentGateway.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat: MCP 九个工具实现与 AgentGateway 装配（headless 导入 VM + 单任务约束）"
```

---

### Task 8: App — MixCutApp 接线 + Settings「Agent」页

**Files:**
- Modify: `MixCut/App/MixCutApp.swift`（init 尾部，`Self.purgeStaleTempFiles()` 之后）
- Modify: `MixCut/Views/Settings/SettingsView.swift`（TabView 加第三个 tab）

**Interfaces:**
- Consumes: `AgentGateway.shared.configure(container:)`、`AgentGateway.restartFromSettings()`、`AgentGateway.enabledKey/portKey/defaultPort/registerCommand`（Task 7）

- [ ] **Step 1: MixCutApp init 里启动 gateway**

在 `MixCutApp.swift` init 的 do 块末尾（`Self.purgeStaleTempFiles()` 之后、`#if DEBUG` 之前）加：

```swift
            // Agent 接入：内嵌 MCP server（仅 127.0.0.1，可在设置中关闭）
            AgentGateway.shared.configure(container: modelContainer)
```

- [ ] **Step 2: SettingsView 加「Agent」tab**

TabView 里 `generalSettings` 之后加：

```swift
                agentSettings
                    .tabItem {
                        Label("Agent", systemImage: "antenna.radiowaves.left.and.right")
                    }
```

在 `generalSettings` 定义之后新增（@AppStorage 属性加到文件顶部 @State 区域）：

```swift
    @AppStorage(AgentGateway.enabledKey) private var agentEnabled = true
    @AppStorage(AgentGateway.portKey) private var agentPort = Int(AgentGateway.defaultPort)
```

```swift
    // MARK: - Agent 接入设置
    private var agentSettings: some View {
        Form {
            Section("本机 Agent 接入（MCP）") {
                Toggle("启用 Agent 服务", isOn: $agentEnabled)
                    .onChange(of: agentEnabled) { _, _ in
                        AgentGateway.shared.restartFromSettings()
                    }
                TextField("端口", value: $agentPort, format: .number.grouping(.never))
                    .onSubmit { AgentGateway.shared.restartFromSettings() }
                    .disabled(!agentEnabled)
                Text("服务只监听 127.0.0.1，仅本机可访问。改端口后回车生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("在 Claude Code 中注册") {
                HStack {
                    Text(AgentGateway.registerCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgentGateway.registerCommand, forType: .string)
                    }
                }
                Text("注册后 Agent 即可：新建项目、批量导入视频、监控分析流水线、重试失败、移除视频。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
```

注意：参照 `generalSettings` 现有写法（是否有 `.formStyle(.grouped)`/padding），保持一致。

- [ ] **Step 3: 编译 + 重启 app + 截图验证 Settings**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3
pkill -x MixCut; sleep 1
open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```

打开设置窗口（⌘,）切到 Agent tab，`screencapture -l <window-id>` 截图确认布局正常、命令行可复制。

- [ ] **Step 4: Commit**

```bash
git add MixCut/App/MixCutApp.swift MixCut/Views/Settings/SettingsView.swift
git commit -m "feat: 启动时装配 Agent 网关；设置页新增 Agent 接入开关/端口/注册命令"
```

---

### Task 9: 端到端验证 — smoke test 脚本 + 真实 MCP 验收 + 回归

**Files:**
- Create: `scripts/mcp_smoke_test.sh`

- [ ] **Step 1: 写 `scripts/mcp_smoke_test.sh`**

```bash
#!/bin/bash
# MCP server 冒烟测试：app 必须已运行。用法：./scripts/mcp_smoke_test.sh [端口]
set -euo pipefail
PORT="${1:-8787}"
URL="http://127.0.0.1:${PORT}/mcp"

call() {
    curl -sS -X POST "$URL" -H 'Content-Type: application/json' -d "$1"
}

echo "== initialize =="
call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' | python3 -m json.tool

echo "== notifications/initialized（应无输出体） =="
call '{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo "== tools/list =="
call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | python3 -c '
import json,sys
r = json.load(sys.stdin)
tools = r["result"]["tools"]
assert len(tools) == 9, f"期望 9 个工具，实际 {len(tools)}"
print("工具:", ", ".join(t["name"] for t in tools))'

echo "== list_projects =="
call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}' | python3 -m json.tool

echo "== create_project（冒烟专用项目） =="
call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_project","arguments":{"name":"MCP冒烟测试"}}}' | python3 -m json.tool

echo "== 错误路径：不存在的项目 =="
call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_project","arguments":{"project_id":"00000000-0000-0000-0000-000000000000"}}}' | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r["result"]["isError"] is True
body = json.loads(r["result"]["content"][0]["text"])
assert body["code"] == "PROJECT_NOT_FOUND", body
print("PROJECT_NOT_FOUND ✓")'

echo "== 错误路径：非法方法 =="
call '{"jsonrpc":"2.0","id":6,"method":"resources/list"}' | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r["error"]["code"] == -32601, r
print("-32601 ✓")'

echo "全部冒烟通过 ✓"
```

`chmod +x scripts/mcp_smoke_test.sh`

- [ ] **Step 2: 跑冒烟**

Run: app 运行状态下 `./scripts/mcp_smoke_test.sh`
Expected: 输出以 `全部冒烟通过 ✓` 结束；UI 项目列表出现「MCP冒烟测试」项目（人眼确认 UI 联动）

- [ ] **Step 3: 真实导入验收（需要一个测试视频）**

从素材目录挑一个已有视频文件（或用 ffmpeg 生成 10s 测试片），curl 调 `import_videos` → 轮询 `get_job` 直到 `state != running` → `list_segments` 有产出 → `remove_video` 移除。全程观察 UI 实时变化。

- [ ] **Step 4: Claude Code 注册验证**

```bash
claude mcp add --transport http mixcut http://127.0.0.1:8787/mcp
claude mcp list
```
Expected: mixcut 显示 connected；然后在 claude 会话里让它调用 `list_projects` 确认能走通。

- [ ] **Step 5: UI 回归（铁律清单）**

人工跑一遍：UI 手动导入视频走完流水线；删除视频出现撤销浮条且撤销有效；切换项目数据联动；素材导入页双击编辑台词。确认全部正常。

- [ ] **Step 6: Commit + 收尾**

```bash
git add scripts/mcp_smoke_test.sh
git commit -m "test: MCP server 冒烟测试脚本"
```

bump 版本号（VERSION + pbxproj 两处 MARKETING_VERSION → 0.9.3）→ Release universal 构建 → 打 `MixCut-v0.9.3.dmg`（按 CLAUDE.md 标准流程）。**不合并 main、不 push、不发 release**——等用户验证。

---

## Self-Review 结论

- Spec 覆盖：9 工具（Task 3 定义 / Task 7 实现）、job 模型（Task 5）、Settings（Task 8）、错误码 6 个（Task 3）、冒烟+验收+回归（Task 9）、`ImportReport`/立即删除（Task 4）——全覆盖。
- 类型一致性：`MCPToolHandlers.Outcome`、`AgentJob.Kind`、`ImportReport` 等签名已在 Interfaces 区块对齐。
- 已知留白（刻意）：pbxproj 收录方式视工程格式而定（Task 5 Step 2 给了两条路径）；`ToastCenter.show`/`MixLog` 签名以现有代码为准（就地确认）。
