import SwiftUI

struct WelcomeView: View {
    @Bindable var projectVM: ProjectViewModel
    @State private var hasAPIKey = true
    @State private var hasWhisperModel = true

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo 和标题
            VStack(spacing: DesignTokens.Spacing.normal) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue, .blue.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Text("MixCut")
                    .font(.system(size: 28, weight: .bold))

                Text("AI 驱动的广告视频混剪工具")
                    .font(DesignTokens.Typography.bodyLarge)
                    .foregroundStyle(.secondary)
            }

            // 功能亮点
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                FeatureRow(icon: "scissors", text: "AI 自动按语义切分视频镜头", color: .blue)
                FeatureRow(icon: "wand.and.stars", text: "智能排列组合生成新广告视频", color: .purple)
                FeatureRow(icon: "square.and.arrow.up", text: "一键导出为可用的 MP4 视频", color: .green)
            }
            .padding(DesignTokens.Padding.page)
            .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // CTA
            Button {
                projectVM.isCreatingProject = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(DesignTokens.Typography.bodyEmphasis)
                    Text("创建新项目")
                        .font(DesignTokens.Typography.bodyLargeEmphasis)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if !projectVM.projects.isEmpty {
                VStack(spacing: DesignTokens.Spacing.compact) {
                    Text("或继续最近的项目")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.tertiary)

                    HStack(spacing: DesignTokens.Spacing.compact) {
                        ForEach(projectVM.projects.filter { $0.status != .archived }.prefix(3)) { project in
                            Button {
                                projectVM.selectedProject = project
                            } label: {
                                HStack(spacing: DesignTokens.Spacing.tight) {
                                    Image(systemName: "film.fill")
                                        .font(DesignTokens.Typography.microRegular)
                                    Text(project.name)
                                        .font(DesignTokens.Typography.captionStrong)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.quaternary.opacity(DesignTokens.Palette.Alpha.strong))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("打开 \(project.name)")
                        }
                    }
                }
            }

            // 依赖状态提示
            if !hasAPIKey || !hasWhisperModel {
                VStack(alignment: .leading, spacing: 6) {
                    if !hasAPIKey {
                        HStack(spacing: 6) {
                            Image(systemName: "key")
                                .font(DesignTokens.Typography.microRegular)
                                .foregroundStyle(.orange)
                            Text("请先在设置中配置 AI API Key")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !hasWhisperModel {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(DesignTokens.Typography.microRegular)
                                .foregroundStyle(.orange)
                            Text("语音识别模型未下载（设置 → 通用 → 语音模型）")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(DesignTokens.Spacing.normal)
                .background(.orange.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            hasAPIKey = KeychainHelper.hasAPIKey(for: KeychainHelper.activeProvider)
            hasWhisperModel = ASRService().isModelAvailable()
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.normal) {
            Image(systemName: icon)
                .font(DesignTokens.Typography.bodyLarge)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(text)
                .font(DesignTokens.Typography.body)
        }
    }
}
