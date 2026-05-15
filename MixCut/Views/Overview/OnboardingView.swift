import SwiftUI

/// 首次启动 4 步使用引导
/// 通过 @AppStorage("hasCompletedOnboarding") 持久化是否已完成
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step: Int = 0
    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .id(step)

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 500)
    }

    // MARK: - 步骤内容

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomePage
        case 1: apiKeyPage
        case 2: importPage
        case 3: generatePage
        default: EmptyView()
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 22) {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    .linearGradient(
                        colors: [.blue, .blue.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(spacing: 6) {
                Text("欢迎使用 MixCut")
                    .font(.system(size: 24, weight: .bold))
                Text("AI 驱动的广告视频混剪工具")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(icon: "scissors", color: .blue,
                                 text: "AI 自动按语义切分视频镜头")
                OnboardingBullet(icon: "wand.and.stars", color: .purple,
                                 text: "智能排列组合生成差异化广告视频")
                OnboardingBullet(icon: "square.and.arrow.up", color: .green,
                                 text: "一键批量导出为可用的 MP4 视频")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var apiKeyPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.fill")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                Text("第一步 · 配置 AI Key")
                    .font(.system(size: 22, weight: .bold))
                Text("MixCut 需要大模型完成语义分析与混剪策略")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(icon: "1.circle.fill", color: .blue,
                                 text: "打开「设置 → API」")
                OnboardingBullet(icon: "2.circle.fill", color: .blue,
                                 text: "选择提供商：千问 / MiniMax / Claude / 自定义")
                OnboardingBullet(icon: "3.circle.fill", color: .blue,
                                 text: "粘贴 API Key 并保存")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            SettingsLink {
                Label("打开设置...", systemImage: "gear")
                    .font(.system(size: 12, weight: .medium))
            }
            .controlSize(.small)
        }
    }

    private var importPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.system(size: 50))
                .foregroundStyle(.blue)

            VStack(spacing: 6) {
                Text("第二步 · 导入广告素材")
                    .font(.system(size: 22, weight: .bold))
                Text("新建项目后把视频拖进来，剩下交给 AI")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(icon: "waveform", color: .blue,
                                 text: "Whisper 本地识别台词（不上传云端）")
                OnboardingBullet(icon: "rectangle.split.3x1", color: .blue,
                                 text: "镜头切分 + I-frame 精准边界对齐")
                OnboardingBullet(icon: "tag.fill", color: .blue,
                                 text: "AI 自动标注语义：产品展示、口播、卖点…")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text("💡 首次分析会自动下载约 1.6GB 的语音识别模型")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var generatePage: some View {
        VStack(spacing: 18) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 50))
                .foregroundStyle(.purple)

            VStack(spacing: 6) {
                Text("第三步 · 生成方案并导出")
                    .font(.system(size: 22, weight: .bold))
                Text("AI 先制定策略，再挑选具体分镜，批量混剪")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(icon: "list.bullet.clipboard", color: .purple,
                                 text: "在「混剪方案」点「生成方案」")
                OnboardingBullet(icon: "sparkles", color: .purple,
                                 text: "AI 自动制定风格、受众、叙事结构")
                OnboardingBullet(icon: "square.and.arrow.up.fill", color: .green,
                                 text: "在「导出」批量输出 MP4 视频文件")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text("🎬 准备好了，开始你的第一个项目吧")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 底部控制

    private var footer: some View {
        HStack {
            Button("跳过") {
                onComplete()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { idx in
                    Circle()
                        .fill(idx == step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 7, height: 7)
                        .animation(.easeInOut(duration: 0.2), value: step)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if step > 0 {
                    Button("上一步") {
                        withAnimation(.easeInOut(duration: 0.25)) { step -= 1 }
                    }
                    .controlSize(.regular)
                }

                if step < totalSteps - 1 {
                    Button("下一步") {
                        withAnimation(.easeInOut(duration: 0.25)) { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("开始使用 MixCut") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - 子组件

private struct OnboardingBullet: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
