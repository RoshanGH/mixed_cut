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

    /// 仅反映本视频的忙碌状态（不同视频互不联动）。
    private var busy: Bool { dubVM.isBusy(videoID: video.id) }

    var body: some View {
        HStack(spacing: 8) {
            Spacer()

            if busy {
                ProgressView().controlSize(.small)
                Text(dubVM.progressText(videoID: video.id))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            } else {
                if variantCount > 0 {
                    Label("\(variantCount) 个变体", systemImage: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green)
                        .help("已生成 \(variantCount) 个配音变体，点开分镜在右侧查看")
                }

                Stepper(value: $variantCountSetting, in: DubbingViewModel.variantCountRange) {
                    Text("×\(variantCountSetting)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .controlSize(.mini)
                .fixedSize()
                .help("每个非「保留原声」分镜要产出的台词变体数量（1–5）")

                Button {
                    Task { await dubVM.rewriteAll(video: video, context: modelContext) }
                } label: {
                    Label(video.clonedVoiceId != nil ? "改写配音" : "克隆并改写配音",
                          systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .controlSize(.small)
                .help("自动克隆原声 → 为本视频所有非「保留原声」分镜改写 \(variantCountSetting) 套台词 → 用克隆嗓音生成配音")
            }
        }
        .alert("配音", isPresented: Binding(get: { dubVM.errorMessage != nil },
                                          set: { if !$0 { dubVM.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(dubVM.errorMessage ?? "") }
    }
}
