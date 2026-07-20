// MixCut/Views/SegmentLibrary/SegmentDubControls.swift
import SwiftUI

/// 分镜卡片上的配音相关控件。无持久化逻辑，动作经 binding/闭包上抛。
struct SegmentDubControls: View {
    @Binding var isVoiceLocked: Bool
    @Binding var treatment: SubtitleTreatment
    let onApplyMaskToAll: () -> Void
    /// 本分镜自己的烧录字幕字号（逐分镜独立，不是全局设置）
    @Binding var fontRatio: Double
    /// 把当前字号套用到**本视频**的所有分镜（与「遮挡区应用到所有分镜」同作用域）
    let onApplyFontSizeToAll: () -> Void

    /// 就地调整字号的弹层
    @State private var showFontSizePopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isVoiceLocked) {
                Label("保留原声", systemImage: "lock.fill")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("明星出镜口播等不可替换的镜头，勾选后不参与改写/配音")

            // 保留原声的分镜不重配也不烧新字幕，字幕处理对其无意义
            if !isVoiceLocked {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "captions.bubble")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.tertiary)
                        Text("字幕处理")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 5) {
                        ForEach(SubtitleTreatment.allCases) { t in
                            treatmentChip(t)
                        }
                    }
                }
                .help("直接烧录=不处理背景直接烧新字幕；模糊虚化=把字幕区域糊掉再烧（不管有没有旧字幕都可用）；纯色遮挡=深色条盖住该区域再烧")

                if treatment.needsMask {
                    Button(action: onApplyMaskToAll) {
                        Label("遮挡区应用到所有分镜", systemImage: "square.on.square")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                }

                // ⚠️ 字幕字号是**全局设置**（影响所有视频的所有分镜）。
                // 早期做法是每张卡各放一个滑条：200 张卡 = 200 个重复控件，
                // 且用户会以为只改当前分镜。后来挪到工具栏，又太远 —— 正在看这张卡的
                // 画面预览时想调字号，得满界面找。
                // 现在：卡片上给**就地入口**，点开是同一个全局设置的弹层，
                // 弹层里写清作用域。控件只有一个实例，但在手边。
                Button {
                    showFontSizePopover = true
                } label: {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "textformat.size")
                            .font(DesignTokens.Typography.micro)
                        Text("字幕字号 \(String(format: "%.1f%%", SubtitleFontSize.clamp(fontRatio) * 100))")
                            .font(DesignTokens.Typography.micro)
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("调整这个分镜的字幕烧录字号。需要统一时，可在弹层里应用到本视频所有分镜。")
                .popover(isPresented: $showFontSizePopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
                        Text("字幕字号")
                            .font(DesignTokens.Typography.labelEmphasis)
                        Text("只影响这一个分镜")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(.secondary)
                        HStack(spacing: DesignTokens.Spacing.compact) {
                            Text("小").font(DesignTokens.Typography.micro).foregroundStyle(.tertiary)
                            Slider(value: $fontRatio,
                                   in: SubtitleFontSize.minRatio...SubtitleFontSize.maxRatio)
                                .frame(width: 180)
                            Text("大").font(DesignTokens.Typography.micro).foregroundStyle(.tertiary)
                            Text(String(format: "%.1f%%", SubtitleFontSize.clamp(fontRatio) * 100))
                                .font(DesignTokens.Typography.caption)
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                        Text("拖动时上方画面里的示例字幕会实时变化，可与原视频字幕比大小。")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: 300, alignment: .leading)

                        Divider()

                        Button {
                            onApplyFontSizeToAll()
                            showFontSizePopover = false
                        } label: {
                            Label("应用到本视频所有分镜", systemImage: "square.on.square")
                        }
                        .controlSize(.small)
                    }
                    .padding(DesignTokens.Spacing.comfortable)
                }
            }
        }
    }

    /// 字幕处理胶囊选项（选中=主题色填充，未选=浅灰），与卡片标签风格统一
    private func treatmentChip(_ t: SubtitleTreatment) -> some View {
        let on = (t == treatment)
        return Text(t.displayName)
            .font(.system(size: 10, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.1)))
            .contentShape(Capsule())
            .onTapGesture { treatment = t }
    }
}
