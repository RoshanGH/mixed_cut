import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider: AIProviderType = KeychainHelper.activeProvider
    @State private var apiKey: String = ""
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

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏 + 关闭按钮
            HStack {
                Text("设置")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
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
                HStack(spacing: 8) {
                    if showAPIKey {
                        TextField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
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
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if selectedProvider == .custom {
                    TextField("API 地址", text: $customBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    TextField("模型名称", text: $customModelName, prompt: Text("gpt-4o"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                } else {
                    if selectedProvider == .claudeRelay {
                        TextField("网关地址", text: $relayBaseURL,
                                  prompt: Text("https://your-relay.example.com/v1"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        Text("要求兼容 OpenAI 协议的转发网关地址")
                            .font(.system(size: 10))
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

                HStack(spacing: 8) {
                    if isAPIKeySaved {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                            Text("已保存")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        }
                    }

                    Spacer()

                    Button("保存") {
                        saveAPIKey()
                    }
                    .controlSize(.small)
                    .disabled(
                        apiKey.isEmpty || apiKey.starts(with: "•") ||
                        (selectedProvider == .custom && (customBaseURL.isEmpty || customModelName.isEmpty)) ||
                        (selectedProvider == .claudeRelay && relayBaseURL.isEmpty)
                    )

                    if isAPIKeySaved {
                        Button("清除", role: .destructive) {
                            clearAPIKey()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                            Text("已就绪")
                                .font(.system(size: 12))
                        }
                    } else if isDownloadingModel {
                        VStack(alignment: .leading, spacing: 4) {
                            if let p = downloadProgress, p.totalBytes > 0 {
                                ProgressView(value: p.fraction)
                                    .controlSize(.small)
                                    .frame(width: 200)
                                HStack(spacing: 6) {
                                    Text(String(format: "%.1f%%", p.fraction * 100))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    Text("\(formatBytes(p.receivedBytes)) / \(formatBytes(p.totalBytes))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    if p.bytesPerSecond > 0 {
                                        Text("• \(formatBytes(Int64(p.bytesPerSecond)))/s")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.small)
                                    Text("连接中…").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                            Button("取消") {
                                downloadTask?.cancel()
                            }
                            .controlSize(.small)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                Text("语音识别需要先下载模型")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Button("下载模型 (~1.6GB)") {
                                downloadWhisperModel()
                            }
                            .controlSize(.small)
                            if let error = modelDownloadError {
                                Text(error)
                                    .font(.system(size: 10))
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
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("在 Finder 中打开")
                            .font(.system(size: 12))
                    }
                }
                .controlSize(.small)
            }

            Section("系统信息") {
                let hw = HardwareProfile.shared

                LabeledContent("芯片型号") {
                    Text(hw.chipDisplayName)
                        .font(.system(size: 12))
                }
                LabeledContent("CPU 核心数") {
                    if hw.isAppleSilicon && hw.performanceCores > 0 && hw.performanceCores < hw.physicalCores {
                        Text("\(hw.physicalCores) 核（\(hw.performanceCores) 性能 + \(hw.physicalCores - hw.performanceCores) 效率）")
                            .font(.system(size: 12))
                    } else {
                        Text("\(hw.physicalCores) 核")
                            .font(.system(size: 12))
                    }
                }
                LabeledContent("内存") {
                    Text("\(hw.memoryGB) GB")
                        .font(.system(size: 12))
                }
                LabeledContent("Media Engine") {
                    Text(hw.mediaEngineDescription)
                        .font(.system(size: 12))
                }
                LabeledContent("GPU 编码加速") {
                    HStack(spacing: 4) {
                        Image(systemName: hw.videoToolboxAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(hw.videoToolboxAvailable ? .green : .red)
                        Text(hw.videoToolboxAvailable ? "VideoToolbox" : "无")
                            .font(.system(size: 12))
                    }
                }
                LabeledContent("Whisper 后端") {
                    Text(hw.whisperBackend)
                        .font(.system(size: 12))
                }
            }

            Section("并发策略") {
                LabeledContent("同时分析视频数") {
                    Text(ConcurrencyPolicy.explainAnalyze())
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("同时导出视频数") {
                    Text(ConcurrencyPolicy.explainExport())
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("同时 ASR 数") {
                    Text(ConcurrencyPolicy.explainASR())
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Section("版本") {
                LabeledContent("应用版本") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Section("关于") {
                LabeledContent("使用引导") {
                    Button {
                        hasCompletedOnboarding = false
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 11))
                            Text("重新查看")
                                .font(.system(size: 12))
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
                        HStack(spacing: 4) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 11))
                            Text("查看")
                                .font(.system(size: 12))
                        }
                    }
                    .controlSize(.small)
                }

                LabeledContent("开发者") {
                    Text("MengGang")
                        .font(.system(size: 12))
                }
                LabeledContent("联系方式") {
                    Text("13462890087")
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
                LabeledContent("GitHub") {
                    Link("RoshanGH/mixed_cut", destination: URL(string: "https://github.com/RoshanGH/mixed_cut")!)
                        .font(.system(size: 12))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func dependencyStatus(installed: Bool, installHint: String) -> some View {
        if installed {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                Text("已安装")
                    .font(.system(size: 12))
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
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

    private func saveAPIKey() {
        guard !apiKey.isEmpty, !apiKey.starts(with: "•") else { return }
        do {
            try KeychainHelper.saveAPIKey(apiKey, for: selectedProvider)

            // 自定义提供商额外保存 Base URL 和模型名
            if selectedProvider == .custom {
                KeychainHelper.customBaseURL = customBaseURL
                KeychainHelper.customModelName = customModelName
                KeychainHelper.setSelectedModel(customModelName, for: .custom)
            }

            // 国内转发网关额外保存网关地址 + 平台
            if selectedProvider == .claudeRelay {
                KeychainHelper.relayBaseURL = relayBaseURL
                KeychainHelper.relayPlatform = relayPlatform
            }

            isAPIKeySaved = true
            MixLog.info("API Key 已保存: provider=\(selectedProvider.displayName)")
            apiKey = "••••••••••••••••••••"
        } catch {
            MixLog.error("保存 API Key 失败: \(error)")
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
