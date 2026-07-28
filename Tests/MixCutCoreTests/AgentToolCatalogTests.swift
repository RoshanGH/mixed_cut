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
