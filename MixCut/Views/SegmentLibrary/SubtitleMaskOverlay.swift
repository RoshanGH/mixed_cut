// MixCut/Views/SegmentLibrary/SubtitleMaskOverlay.swift
import SwiftUI

/// 9:16 预览上的可拖拽/可调高遮挡框。父容器需给定 9:16 尺寸。
struct SubtitleMaskOverlay: View {
    @Binding var rect: SubtitleMaskRect

    /// 拖拽结束时回调一次（用于松手后保存，避免拖拽期间高频写 SwiftData）
    var onCommit: () -> Void = {}

    /// 拖拽期间的本地草稿，nil 表示当前未处于拖拽状态
    @State private var draft: SubtitleMaskRect?

    private let handleHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // 显示用：拖拽中用草稿，否则用绑定值
            let active = draft ?? rect
            let px = active.pixelRect(width: w, height: h)

            ZStack(alignment: .topLeading) {
                // 遮挡区域：半透明蓝框，可整体上下拖
                Rectangle()
                    .fill(Color.accentColor.opacity(0.28))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: px.width, height: px.height)
                    .offset(x: px.x, y: px.y)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // translation 是从手势起点到当前的累计位移，
                                // 拖拽期间 rect 不变，始终以 rect 为基准，避免叠加翻倍
                                let dy = Double(value.translation.height) / Double(h)
                                draft = rect.movedBy(dy: dy)
                            }
                            .onEnded { _ in
                                if let d = draft { rect = d }
                                draft = nil
                                onCommit()
                            }
                    )

                // 底部调高手柄
                Capsule()
                    .fill(Color.white)
                    .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 40, height: handleHeight)
                    .position(x: px.x + px.width / 2,
                              y: px.y + px.height)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // 同上：以稳定的 rect 为基准，按累计位移调整高度
                                let dH = Double(value.translation.height) / Double(h)
                                draft = rect.resizedBy(dHeight: dH)
                            }
                            .onEnded { _ in
                                if let d = draft { rect = d }
                                draft = nil
                                onCommit()
                            }
                    )
            }
        }
    }
}
