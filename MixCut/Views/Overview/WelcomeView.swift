import SwiftUI

struct WelcomeView: View {
    @Bindable var projectVM: ProjectViewModel
    @State private var hasAPIKey = true
    @State private var hasWhisperModel = true

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo 和标题
            VStack(spacing: 12) {
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
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            // 功能亮点
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "scissors", text: "AI 自动按语义切分视频镜头", color: .blue)
                FeatureRow(icon: "wand.and.stars", text: "智能排列组合生成新广告视频", color: .purple)
                FeatureRow(icon: "square.and.arrow.up", text: "一键导出为可用的 MP4 视频", color: .green)
            }
            .padding(20)
            .background(.quaternary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // CTA
            Button {
                projectVM.isCreatingProject = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("创建新项目")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if !projectVM.projects.isEmpty {
                Text("或从左侧选择一个已有项目")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            // 依赖状态提示
            if !hasAPIKey || !hasWhisperModel {
                VStack(alignment: .leading, spacing: 6) {
                    if !hasAPIKey {
                        HStack(spacing: 6) {
                            Image(systemName: "key")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text("请先在设置中配置 AI API Key")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !hasWhisperModel {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text("语音识别模型未下载（设置 → 通用 → 语音模型）")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(text)
                .font(.system(size: 13))
        }
    }
}
