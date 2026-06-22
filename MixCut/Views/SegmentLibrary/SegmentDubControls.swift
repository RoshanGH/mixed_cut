// MixCut/Views/SegmentLibrary/SegmentDubControls.swift
import SwiftUI

/// 分镜卡片上的配音相关控件。无持久化逻辑，动作经 binding/闭包上抛。
struct SegmentDubControls: View {
    @Binding var isVoiceLocked: Bool
    @Binding var hasHardSubtitle: Bool
    @Binding var maskStyle: MaskStyle
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

            Toggle(isOn: $hasHardSubtitle) {
                Label("硬字幕遮挡", systemImage: "rectangle.dashed")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("原片该分镜已有烧死的字幕，勾选后用遮挡条盖住")

            if hasHardSubtitle {
                Picker("样式", selection: $maskStyle) {
                    ForEach(MaskStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)

                Button(action: onApplyMaskToAll) {
                    Label("应用到本视频所有分镜", systemImage: "square.on.square")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }
        }
    }
}
