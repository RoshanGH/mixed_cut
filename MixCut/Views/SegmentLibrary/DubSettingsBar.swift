import SwiftUI

/// 分镜素材库顶部「配音」栏：一键改写台词（自动克隆原声 → 改写 → 克隆配音）。
/// 已去掉手动选音色：新台词统一用克隆出来的原主播嗓音配音。
struct DubSettingsBar: View {
    let video: Video
    @Bindable var dubVM: DubbingViewModel
    @Environment(\.modelContext) private var modelContext

    /// 每个非锁定分镜要产出的台词变体数量（全局设置，1...5）。
    @AppStorage("dubVariantCount") private var variantCountSetting: Int = DubbingViewModel.defaultVariantCount

    /// 当前视频已生成的配音变体总数。
    private var variantCount: Int {
        video.segments.reduce(0) { $0 + $1.segmentDubs.count }
    }

    private var busy: Bool { dubVM.isCloning || dubVM.isRewriting }

    var body: some View {
        HStack(spacing: 10) {
            Label("配音", systemImage: "waveform")
                .font(.subheadline.weight(.semibold))

            if video.clonedVoiceId != nil {
                Label("已克隆原声", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Text("新台词将用克隆的原主播嗓音配音")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if variantCount > 0 {
                Text("· 已生成 \(variantCount) 个变体，点开分镜在右侧查看")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if busy {
                ProgressView().controlSize(.small)
                Text(dubVM.isCloning ? dubVM.cloneProgress : dubVM.rewriteProgress)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Stepper(value: $variantCountSetting, in: DubbingViewModel.variantCountRange) {
                    Text("每镜变体 \(variantCountSetting) 套")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .controlSize(.small)
                .fixedSize()
                .help("每个非「保留原声」分镜要产出的台词变体数量（1–5）")

                Button {
                    Task { await dubVM.rewriteAll(video: video, context: modelContext) }
                } label: {
                    Label("一键改写台词", systemImage: "wand.and.stars")
                }
                .help("自动克隆原声 → 为所有非「保留原声」分镜改写 \(variantCountSetting) 套台词 → 用克隆嗓音生成配音")
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
        .alert("配音", isPresented: Binding(get: { dubVM.errorMessage != nil },
                                          set: { if !$0 { dubVM.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(dubVM.errorMessage ?? "") }
    }
}
