import Foundation
import Testing
@testable import MixCutCore

@Suite("AgentToolCatalog")
struct AgentToolCatalogTests {
    @Test("13 个工具且命名齐全")
    func allTools() {
        let names = AgentToolCatalog.all.map(\.name)
        #expect(names == [
            "list_projects", "get_project", "list_segments", "list_schemes", "get_job",
            "create_project", "import_videos", "retry_analysis", "retry_asr", "remove_video",
            "generate_schemes", "export_scheme", "delete_project",
        ])
    }

    @Test("破坏性工具带 destructiveHint，只读工具带 readOnlyHint")
    func annotations() throws {
        func hints(_ name: String) throws -> [String: Any] {
            let tool = try #require(AgentToolCatalog.all.first { $0.name == name })
            let json = try #require(tool.annotationsJSON)
            return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        #expect(try hints("delete_project")["destructiveHint"] as? Bool == true)
        #expect(try hints("remove_video")["destructiveHint"] as? Bool == true)
        #expect(try hints("list_projects")["readOnlyHint"] as? Bool == true)
        #expect(try hints("export_scheme")["destructiveHint"] as? Bool == false)
    }

    @Test("delete_project schema 含 confirm 二次确认参数")
    func deleteProjectConfirm() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "delete_project" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let props = try #require(obj["properties"] as? [String: Any])
        #expect(props["confirm"] != nil)
    }

    @Test("export_scheme schema 声明必填参数")
    func exportSchemeSchema() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "export_scheme" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let required = try #require(obj["required"] as? [String])
        #expect(Set(required) == ["scheme_ids", "output_dir"])
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
