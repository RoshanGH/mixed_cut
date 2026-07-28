import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider: AIProviderType = KeychainHelper.activeProvider
    @State private var apiKey: String = ""
    @State private var isTestingConnection = false
    /// 测试连接结果：(是否成功, 展示给用户的一句话)
    @State private var connectionTestResult: (ok: Bool, message: String)?
    @State private var isAPIKeySaved = false
    @State private var showAPIKey = false
    @State private var selectedModel: String = ""
    @State private var customBaseURL: String = ""
    @State private var customModelName: String = ""
    @State private var relayBaseURL: String = ""
    @State private var relayPlatform: RelayPlatform = KeychainHelper.relayPlatform
    @State private var isDownloadingModel = false
    @State private var modelDownloadError: String?
    @State private var downloadProgress: DownloadProgress?
    @State private var downloadTask: Task<Void, Never>?
    @State private var whisperModelReady = false

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AgentGateway.enabledKey) private var agentEnabled = true
    @AppStorage(AgentGateway.portKey) private var agentPort = Int(AgentGateway.defaultPort)

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏 + 关闭按钮
            HStack {
                Text("设置")
                    .font(DesignTokens.Typography.bodyLargeEmphasis)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(DesignTokens.Typography.headline)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭设置")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            TabView {
                apiKeySettings
                    .tabItem {
                        Label("API", systemImage: "key")
                    }

                generalSettings
                    .tabItem {
                        Label("通用", systemImage: "gear")
                    }

                agentSettings
                    .tabItem {
                        Label("Agent", systemImage: "antenna.radiowaves.left.and.right")
                    }
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            loadProviderState()
            whisperModelReady = ASRService().isModelAvailable()
        }
    }

    // MARK: - API Key 设置
    private var apiKeySettings: some View {
        Form {
            Section("AI 提供商") {
                Picker("提供商", selection: $selectedProvider) {
                    ForEach(AIProviderType.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: selectedProvider) { _, newValue in
                    KeychainHelper.activeProvider = newValue
                    loadProviderState()
                }
            }

            Section("\(selectedProvider.displayName) 配置") {
                HStack(spacing: DesignTokens.Spacing.compact) {
                    if showAPIKey {
                        TextField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(DesignTokens.Typography.labelMono)
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showAPIKey.toggle()
                        if showAPIKey {
                            if let realKey = KeychainHelper.getAPIKey(for: selectedProvider) {
                                apiKey = realKey
                            }
                        } else {
                            if isAPIKeySaved {
                                apiKey = "••••••••••••••••••••"
                            }
                        }
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showAPIKey ? "隐藏密钥" : "显示密钥")
                }

                if selectedProvider == .custom {
                    TextField("API 地址", text: $customBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .font(DesignTokens.Typography.labelMono)

                    TextField("模型名称", text: $customModelName, prompt: Text("gpt-4o"))
                        .textFieldStyle(.roundedBorder)
                        .font(DesignTokens.Typography.labelMono)
                } else {
                    if selectedProvider == .claudeRelay {
                        TextField("网关地址", text: $relayBaseURL,
                                  prompt: Text("https://your-relay.example.com/v1"))
                            .textFieldStyle(.roundedBorder)
                            .font(DesignTokens.Typography.labelMono)

                        Text("要求兼容 OpenAI 协议的转发网关地址")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.tertiary)

                        Picker("平台", selection: $relayPlatform) {
                            ForEach(RelayPlatform.allCases) { platform in
                                Text(platform.displayName).tag(platform)
                            }
                        }
                        .onChange(of: relayPlatform) { _, newValue in
                            KeychainHelper.relayPlatform = newValue
                            // 切换平台后将模型重置为新平台的默认模型
                            selectedModel = newValue.defaultModel
                            KeychainHelper.setSelectedModel(selectedModel, for: .claudeRelay)
                        }
                    }

                    Picker("模型", selection: $selectedModel) {
                        ForEach(selectedProvider.models, id: \.self) { model in
                            Text(selectedProvider.modelDisplayName(model)).tag(model)
                        }
                    }
                    .onChange(of: selectedModel) { _, newValue in
                        KeychainHelper.setSelectedModel(newValue, for: selectedProvider)
                    }
                }

                HStack(spacing: DesignTokens.Spacing.compact) {
                    if isAPIKeySaved {
                        HStack(spacing: DesignTokens.Spacing.tight) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(DesignTokens.Typography.label)
                                .foregroundStyle(.green)
                            Text("已保存")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    Spacer()

                    Button("保存") {
                        saveAPIKey()
                    }
                    .controlSize(.small)
                    // Key 已保存（显示为掩码）时**仍可保存**——因为接口地址 / 模型名是独立可改的。
                    // 原先掩码态一律禁用，导致自定义提供商存过 Key 后再也改不了地址和模型名。
                    .disabled(
                        (apiKey.isEmpty && !isAPIKeySaved) ||
                        (selectedProvider == .custom && (customBaseURL.isEmpty || customModelName.isEmpty)) ||
                        (selectedProvider == .claudeRelay && relayBaseURL.isEmpty) ||
                        endpointURLProblem != nil
                    )

                    // 测试连接：Key 填错 / 过期 / 没开通模型权限，以前要等导入流水线跑到
                    // 第 5 步 AI 分析（十几分钟后）才暴露。这里花 1 秒当场验明。
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTestingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试连接")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isTestingConnection || !isAPIKeySaved)

                    if isAPIKeySaved {
                        Button("清除", role: .destructive) {
                            clearAPIKey()
                        }
                        .controlSize(.small)
                    }
                }

                // 地址填错时**当场说明为什么不能保存**，而不是把保存按钮灰掉让用户干瞪眼
                if let problem = endpointURLProblem {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DesignTokens.Palette.Status.warning)
                        Text(problem)
                            .font(DesignTokens.Typography.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }

                if let result = connectionTestResult {
                    HStack(spacing: 6) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.ok ? DesignTokens.Palette.Status.success : DesignTokens.Palette.Status.warning)
                        Text(result.message)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(result.ok ? .secondary : .primary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// 发一次最小请求验证 Key 是否真的可用，把错误提前到"填 Key 的当下"。
    private func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        defer { isTestingConnection = false }

        let started = Date()
        do {
            let provider = AIProviderManager.createProvider(for: selectedProvider)
            _ = try await provider.generateText(prompt: "ping")
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            connectionTestResult = (true, "连接正常 · \(selectedProvider.displayName) · \(ms)ms")
        } catch {
            connectionTestResult = (false, FriendlyError.reason(for: error))
        }
    }

    // MARK: - 通用设置
    private var generalSettings: some View {
        Form {
            Section("视频处理") {
                LabeledContent("FFmpeg") {
                    let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil, inDirectory: "bin") != nil
                        || Bundle.main.path(forResource: "ffmpeg", ofType: nil) != nil
                    let system = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
                        .contains { FileManager.default.fileExists(atPath: $0) }
                    dependencyStatus(installed: bundled || system, installHint: "已内置于应用中")
                }

                LabeledContent("Whisper") {
                    dependencyStatus(installed: ASRService.isAvailable, installHint: "已内置于应用中")
                }

                LabeledContent("语音模型") {
                    if whisperModelReady {
                        HStack(spacing: DesignTokens.Spacing.tight) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(DesignTokens.Typography.label)
                                .foregroundStyle(.green)
                            Text("已就绪")
                                .font(DesignTokens.Typography.label)
                        }
                    } else if isDownloadingModel {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                            if let p = downloadProgress, p.totalBytes > 0 {
                                ProgressView(value: p.fraction)
                                    .controlSize(.small)
                                    .frame(width: 200)
                                HStack(spacing: 6) {
                                    Text(String(format: "%.1f%%", p.fraction * 100))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    Text("\(formatBytes(p.receivedBytes)) / \(formatBytes(p.totalBytes))")
                                        .font(DesignTokens.Typography.microMono)
                                        .foregroundStyle(.secondary)
                                    if p.bytesPerSecond > 0 {
                                        Text("• \(formatBytes(Int64(p.bytesPerSecond)))/s")
                                            .font(DesignTokens.Typography.microMono)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                HStack(spacing: DesignTokens.Spacing.tight) {
                                    ProgressView().controlSize(.small)
                                    Text("连接中…").font(DesignTokens.Typography.label).foregroundStyle(.secondary)
                                }
                            }
                            Button("取消") {
                                downloadTask?.cancel()
                            }
                            .controlSize(.small)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                            HStack(spacing: DesignTokens.Spacing.tight) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.orange)
                                Text("语音识别需要先下载模型")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("下载模型 (~1.6GB)") {
                                downloadWhisperModel()
                            }
                            .controlSize(.small)
                            if let error = modelDownloadError {
                                Text(error)
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }

            Section("存储") {
                LabeledContent("数据目录") {
                    Text(FileHelper.appSupportDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }

                Button {
                    NSWorkspace.shared.open(FileHelper.appSupportDirectory)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "folder")
                            .font(DesignTokens.Typography.caption)
                        Text("在 Finder 中打开")
                            .font(DesignTokens.Typography.label)
                    }
                }
                .controlSize(.small)
            }

            Section("系统信息") {
                let hw = HardwareProfile.shared

                LabeledContent("芯片型号") {
                    Text(hw.chipDisplayName)
                        .font(DesignTokens.Typography.label)
                }
                LabeledContent("CPU 核心数") {
                    if hw.isAppleSilicon && hw.performanceCores > 0 && hw.performanceCores < hw.physicalCores {
                        Text("\(hw.physicalCores) 核（\(hw.performanceCores) 性能 + \(hw.physicalCores - hw.performanceCores) 效率）")
                            .font(DesignTokens.Typography.label)
                    } else {
                        Text("\(hw.physicalCores) 核")
                            .font(DesignTokens.Typography.label)
                    }
                }
                LabeledContent("内存") {
                    Text("\(hw.memoryGB) GB")
                        .font(DesignTokens.Typography.label)
                }
                LabeledContent("Media Engine") {
                    Text(hw.mediaEngineDescription)
                        .font(DesignTokens.Typography.label)
                }
                LabeledContent("GPU 编码加速") {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: hw.videoToolboxAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(hw.videoToolboxAvailable ? .green : .red)
                        Text(hw.videoToolboxAvailable ? "VideoToolbox" : "无")
                            .font(DesignTokens.Typography.label)
                    }
                }
                LabeledContent("Whisper 后端") {
                    Text(hw.whisperBackend)
                        .font(DesignTokens.Typography.label)
                }
            }

            Section("并发策略") {
                LabeledContent("同时分析视频数") {
                    Text(ConcurrencyPolicy.explainAnalyze())
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("同时导出视频数") {
                    Text(ConcurrencyPolicy.explainExport())
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("同时 ASR 数") {
                    Text(ConcurrencyPolicy.explainASR())
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
            }

            Section("版本") {
                LabeledContent("应用版本") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
            }

            Section("关于") {
                LabeledContent("使用引导") {
                    Button {
                        hasCompletedOnboarding = false
                        dismiss()
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.tight) {
                            Image(systemName: "questionmark.circle")
                                .font(DesignTokens.Typography.caption)
                            Text("重新查看")
                                .font(DesignTokens.Typography.label)
                        }
                    }
                    .controlSize(.small)
                }

                LabeledContent("键盘快捷键") {
                    Button {
                        dismiss()
                        // 延迟 让 dismiss 完成再发通知
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            NotificationCenter.default.post(name: .mixCutShowShortcuts, object: nil)
                        }
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.tight) {
                            Image(systemName: "keyboard")
                                .font(DesignTokens.Typography.caption)
                            Text("查看")
                                .font(DesignTokens.Typography.label)
                        }
                    }
                    .controlSize(.small)
                }

                LabeledContent("开发者") {
                    Text("MengGang")
                        .font(DesignTokens.Typography.label)
                }
                LabeledContent("微信") {
                    Text("13462890087")
                        .font(DesignTokens.Typography.label)
                        .textSelection(.enabled)
                }
                LabeledContent("GitHub") {
                    Link("RoshanGH/mixed_cut", destination: URL(string: "https://github.com/RoshanGH/mixed_cut")!)
                        .font(DesignTokens.Typography.label)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

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
                    .font(DesignTokens.Typography.label)
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
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func dependencyStatus(installed: Bool, installHint: String) -> some View {
        if installed {
            HStack(spacing: DesignTokens.Spacing.tight) {
                Image(systemName: "checkmark.circle.fill")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.green)
                Text("已安装")
                    .font(DesignTokens.Typography.label)
            }
        } else {
            HStack(spacing: DesignTokens.Spacing.tight) {
                Image(systemName: "xmark.circle.fill")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.red)
                Text(installHint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 操作

    private func loadProviderState() {
        isAPIKeySaved = KeychainHelper.hasAPIKey(for: selectedProvider)

        // 历史保存的 model ID 可能已被新版本移除，回退到 defaultModel
        let stored = KeychainHelper.selectedModel(for: selectedProvider)
        if selectedProvider == .custom {
            selectedModel = stored
        } else if selectedProvider.models.contains(stored) {
            selectedModel = stored
        } else {
            selectedModel = selectedProvider.defaultModel
            KeychainHelper.setSelectedModel(selectedModel, for: selectedProvider)
        }

        customBaseURL = KeychainHelper.customBaseURL
        customModelName = KeychainHelper.customModelName
        relayBaseURL = KeychainHelper.relayBaseURL
        relayPlatform = KeychainHelper.relayPlatform
        showAPIKey = false
        if isAPIKeySaved {
            apiKey = "••••••••••••••••••••"
        } else {
            apiKey = ""
        }
    }

    /// 接口地址填得不对时的具体说明；没问题返回 nil。
    ///
    /// 在**保存前**就拦下来。否则地址错了要等到导入流水线跑到 AI 分析那步才炸，
    /// 报错还只是一句"连接失败，请检查网络"，把排查方向完全带偏。
    private var endpointURLProblem: String? {
        let raw: String
        switch selectedProvider {
        case .custom:      raw = customBaseURL
        case .claudeRelay: raw = relayBaseURL
        default:           return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }   // 空由 disabled 条件另行处理

        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            return "接口地址需要以 https:// 开头（例如 https://api.example.com/v1）"
        }
        guard let url = URL(string: trimmed), url.host?.isEmpty == false else {
            return "接口地址格式不合法，请检查是否有多余的空格或中文字符"
        }
        if trimmed.hasSuffix("/chat/completions") || trimmed.hasSuffix("/messages") {
            return "这里只填根地址（通常以 /v1 结尾），不要带 /chat/completions 或 /messages"
        }
        return nil
    }

    private func saveAPIKey() {
        // ⚠️ 必须 trim：从网页复制 Key 极易带上尾部空格或换行，
        // 存进去之后每一次 AI 调用都会 401，而错误信息只会说"Key 无效"，
        // 用户肉眼看输入框里的 Key 明明是对的，根本查不出问题。
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // 接口地址与模型名即使不改 Key 也要能单独保存（见下方 saveEndpointConfig 的说明）
        saveEndpointConfig()

        guard !trimmedKey.isEmpty, !trimmedKey.starts(with: "•") else { return }
        do {
            try KeychainHelper.saveAPIKey(trimmedKey, for: selectedProvider)
            isAPIKeySaved = true
            MixLog.info("API Key 已保存: provider=\(selectedProvider.displayName)")
            apiKey = "••••••••••••••••••••"
            connectionTestResult = nil
        } catch {
            // 保存失败以前只写日志，界面上「已保存」的绿标不出现但没有任何原因
            connectionTestResult = (false, "保存失败：\(FriendlyError.reason(for: error))")
        }
    }

    /// 保存接口地址 / 模型名 / 网关平台。
    ///
    /// ⚠️ 必须与 Key 的保存**解耦**。原先这些只在 `saveAPIKey` 里落盘，而保存成功后
    /// `apiKey` 会变成掩码 `••••`，`saveAPIKey` 开头又 `guard !starts(with:"•")` 直接返回 ——
    /// 于是用「自定义 / 转发网关」的用户存过 Key 之后就**再也改不了接口地址和模型名**，
    /// 只能先清除 Key 再重新粘贴一遍。
    private func saveEndpointConfig() {
        if selectedProvider == .custom {
            KeychainHelper.customBaseURL = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainHelper.customModelName = model
            KeychainHelper.setSelectedModel(model, for: .custom)
        }
        if selectedProvider == .claudeRelay {
            KeychainHelper.relayBaseURL = relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainHelper.relayPlatform = relayPlatform
        }
    }

    private func clearAPIKey() {
        try? KeychainHelper.removeAPIKey(for: selectedProvider)
        isAPIKeySaved = false
        apiKey = ""
    }

    private func downloadWhisperModel() {
        isDownloadingModel = true
        modelDownloadError = nil
        downloadProgress = nil
        downloadTask = Task { @MainActor in
            do {
                let asr = ASRService()
                _ = try await asr.downloadModelIfNeeded(
                    modelName: "ggml-large-v3-turbo",
                    onProgress: { progress in
                        Task { @MainActor in
                            downloadProgress = progress
                        }
                    }
                )
                whisperModelReady = true
            } catch is CancellationError {
                modelDownloadError = "已取消"
            } catch {
                modelDownloadError = error.localizedDescription
            }
            isDownloadingModel = false
            downloadProgress = nil
            downloadTask = nil
        }
    }

    /// 把字节数格式化为 KB / MB / GB
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
