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
