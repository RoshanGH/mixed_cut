import SwiftUI

/// 全局 Toast 状态管理（@Observable 单例）
@Observable
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    var current: ToastPayload?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String, icon: String = "checkmark.circle.fill", style: InlineBanner.Style = .success, duration: Double = 2.2,
              actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            current = ToastPayload(id: UUID(), text: text, icon: icon, style: style, actionTitle: actionTitle, action: action)
        }
        // 带操作按钮的 Toast 给更长的停留时间，方便用户来得及点「撤销」
        let effectiveDuration = actionTitle != nil ? max(duration, 4.0) : duration
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(effectiveDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self?.current = nil
            }
        }
    }

    /// 立即清除当前 Toast（如用户点了操作按钮后）
    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            current = nil
        }
    }
}

struct ToastPayload: Identifiable, Equatable {
    let id: UUID
    let text: String
    let icon: String
    let style: InlineBanner.Style
    /// 可选操作按钮标题（如「撤销」），为 nil 时不显示按钮
    let actionTitle: String?
    /// 点击操作按钮执行的闭包（@MainActor，不参与 Equatable 比较）
    let action: (@MainActor () -> Void)?

    // 闭包不可比较，按 id 判等即可（id 全局唯一）
    static func == (lhs: ToastPayload, rhs: ToastPayload) -> Bool {
        lhs.id == rhs.id
    }
}

/// Toast 显示视图（应用根视图叠加）
struct ToastOverlay: View {
    @State private var toastCenter = ToastCenter.shared

    var body: some View {
        VStack {
            if let payload = toastCenter.current {
                HStack(spacing: 8) {
                    Image(systemName: payload.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(payload.style.color)
                    Text(payload.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))

                    if let actionTitle = payload.actionTitle {
                        Divider()
                            .frame(height: 14)
                        Button {
                            payload.action?()
                            toastCenter.dismiss()
                        } label: {
                            Text(actionTitle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .overlay(
                    Capsule().stroke(payload.style.color.opacity(0.15), lineWidth: 1)
                )
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                // 仅在有操作按钮时允许点击，避免无按钮的提示挡住下层交互
                .allowsHitTesting(payload.actionTitle != nil)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 50)
            }
            Spacer()
                .allowsHitTesting(false)
        }
    }
}
