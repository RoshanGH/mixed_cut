// MixCut/Views/SegmentLibrary/SegmentDubControls.swift
import SwiftUI

/// 分镜卡片上的配音相关控件。无持久化逻辑，动作经 binding/闭包上抛。
struct SegmentDubControls: View {
    @Binding var isVoiceLocked: Bool
    @Binding var treatment: SubtitleTreatment
    let onApplyMaskToAll: () -> Void

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
                    HStack(spacing: 4) {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text("字幕处理")
                            .font(.system(size: 10, weight: .medium))
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
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
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
