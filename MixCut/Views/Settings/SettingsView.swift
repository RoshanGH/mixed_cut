import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider: AIProviderType = KeychainHelper.activeProvider
    @State private var apiKey: String = ""
    @State private var isAPIKeySaved = false
    @State private var showAPIKey = false
    @State private var selectedModel: String = ""
    @State private var isDownloadingModel = false
    @State private var modelDownloadError: String?
    @State private var whisperModelReady = false

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

                Picker("模型", selection: $selectedModel) {
                    ForEach(selectedProvider.models, id: \.self) { model in
                        Text(selectedProvider.modelDisplayName(model)).tag(model)
                    }
                }
                .onChange(of: selectedModel) { _, newValue in
                    KeychainHelper.setSelectedModel(newValue, for: selectedProvider)
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
                    .disabled(apiKey.isEmpty || apiKey.starts(with: "•"))

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
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("下载中...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
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
                LabeledContent("CPU 核心数") {
                    Text("\(ProcessInfo.processInfo.activeProcessorCount) 核")
                        .font(.system(size: 12))
                }
                LabeledContent("同时分析视频数") {
                    let cores = ProcessInfo.processInfo.activeProcessorCount
                    Text("最多 \(max(1, cores / 2)) 个")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("同时导出视频数") {
                    let cores = ProcessInfo.processInfo.activeProcessorCount
                    Text("最多 \(max(1, min(8, (cores - 2) / 2))) 个")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("版本") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
        selectedModel = KeychainHelper.selectedModel(for: selectedProvider)
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
            isAPIKeySaved = true
            MixLog.info("API Key 已保存: provider=\(selectedProvider.displayName), keyLength=\(apiKey.count)")
            apiKey = "••••••••••••••••••••"
            // 验证保存是否成功
            let saved = KeychainHelper.hasAPIKey(for: selectedProvider)
            MixLog.info("保存验证: hasKey=\(saved)")
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
        Task {
            do {
                let asr = ASRService()
                _ = try await asr.downloadModelIfNeeded(modelName: "ggml-large-v3-turbo")
                whisperModelReady = true
            } catch {
                modelDownloadError = error.localizedDescription
            }
            isDownloadingModel = false
        }
    }
}
