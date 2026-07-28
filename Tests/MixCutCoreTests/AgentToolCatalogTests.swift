import Foundation
import Testing
@testable import MixCutCore

@Suite("AgentToolCatalog")
struct AgentToolCatalogTests {
    @Test("22 个工具且命名齐全")
    func allTools() {
        let names = AgentToolCatalog.all.map(\.name)
        #expect(names == [
            "list_projects", "get_project", "list_segments", "list_schemes", "get_job",
            "create_project", "import_videos", "retry_analysis", "retry_asr", "remove_video",
            "generate_schemes", "export_scheme", "delete_project",
            "update_segment_tags", "adjust_segment_boundary", "set_subtitle_mode",
            "set_voice_keep_original", "set_dub_participation", "generate_voice_variants",
            "delete_segments", "create_custom_scheme", "export_segments",
        ])
    }

    @Test("分镜工具的 selector 参数齐全")
    func segmentSelectorSchema() throws {
        for name in ["update_segment_tags", "adjust_segment_boundary", "set_subtitle_mode",
                     "set_voice_keep_original", "set_dub_participation", "generate_voice_variants",
                     "delete_segments", "export_segments"] {
            let tool = try #require(AgentToolCatalog.all.first { $0.name == name })
            let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
            let props = try #require(obj["properties"] as? [String: Any])
            for key in ["project_id", "video_no", "segment_nos", "segment_ids"] {
                #expect(props[key] != nil, "\(name) 缺 \(key)")
            }
        }
    }

    @Test("set_subtitle_mode 只认三档中文枚举")
    func subtitleModeEnum() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "set_subtitle_mode" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let props = try #require(obj["properties"] as? [String: Any])
        let mode = try #require(props["mode"] as? [String: Any])
        #expect(mode["enum"] as? [String] == ["直接烧录", "模糊虚化", "纯色遮挡"])
    }

    @Test("delete_segments 带 destructiveHint")
    func deleteSegmentsAnnotation() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "delete_segments" })
        let json = try #require(tool.annotationsJSON)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["destructiveHint"] as? Bool == true)
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
