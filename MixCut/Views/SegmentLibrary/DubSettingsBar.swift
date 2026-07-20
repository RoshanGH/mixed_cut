import SwiftUI

/// 分镜素材库顶部「配音」栏：一键改写台词（自动克隆原声 → 改写 → 克隆配音）。
/// 已去掉手动选音色：新台词统一用克隆出来的原主播嗓音配音。
struct DubSettingsBar: View {
    let video: Video
    @Bindable var dubVM: DubbingViewModel
    @Environment(\.modelContext) private var modelContext

    /// 每个非锁定分镜要产出的台词变体数量（全局设置，1...5）。
    @AppStorage("dubVariantCount") private var variantCountSetting: Int = DubbingViewModel.defaultVariantCount
    /// 计费确认弹窗
    @State private var showRewriteConfirm = false

    /// 会被改写的分镜数（「保留原声」的不参与），用于在确认弹窗里说清规模
    private var eligibleSegmentCount: Int {
        video.segments.filter { !$0.isVoiceLocked }.count
    }

    /// 当前视频已生成的配音变体总数。
    ///
    /// ⚠️ 性能：这原本是计算属性，每次渲染都要遍历全部分镜并触发 `segmentDubs` 关系 faulting；
    /// 而本视图持有 `@Bindable dubVM`，配音进度每跳一次都会重跑一遍。改为缓存，
    /// 仅在进入/切换视频与配音忙碌状态结束时刷新。
    @State private var variantCount: Int = 0

    private func refreshVariantCount() {
        variantCount = video.segments.reduce(0) { $0 + $1.segmentDubs.count }
    }

    /// 仅反映本视频的忙碌状态（不同视频互不联动）。
    private var busy: Bool { dubVM.isBusy(videoID: video.id) }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
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
                    // 计费确认：这一下会触发 demucs 人声分离 + 音色克隆 + N 套 AI 改写
                    // + 全部分镜 × N 段 TTS 合成，是全 App 最贵的操作之一，手滑点到代价很大。
                    // 与「画面替换·重新生成」的确认标准保持一致。
                    showRewriteConfirm = true
                } label: {
                    Label(video.clonedVoiceId != nil ? "改写配音" : "克隆并改写配音",
                          systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .controlSize(.small)
                .help("自动克隆原声 → 为本视频所有非「保留原声」分镜改写 \(variantCountSetting) 套台词 → 用克隆嗓音生成配音")
            }
        }
        .confirmationDialog("确定要开始改写配音吗？", isPresented: $showRewriteConfirm) {
            Button("开始（按次计费）") {
                Task { await dubVM.rewriteAll(video: video, context: modelContext) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将为本视频 \(eligibleSegmentCount) 个分镜各生成 \(variantCountSetting) 套改写台词，并用克隆嗓音合成约 \(eligibleSegmentCount * variantCountSetting) 段配音。按次计费，耗时较长。")
        }
        .task(id: video.id) { refreshVariantCount() }
        // 配音跑完（busy 由 true 变 false）时刷新计数
        .onChange(of: busy) { _, isBusy in
            if !isBusy { refreshVariantCount() }
        }
        // 配音错误的 alert 已上移到 SegmentLibraryView 顶层。
        // 挂在这里不可靠：本组件只在「普通视频」分组标题行渲染，且外层是 LazyVStack，
        // 一旦分组标题滚出可视区，宿主被回收，报错就再也弹不出来了。
    }
}
