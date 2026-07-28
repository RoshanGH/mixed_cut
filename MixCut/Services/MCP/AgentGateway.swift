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
