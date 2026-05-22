import SwiftUI

/// 全局 Toast 状态管理（@Observable 单例）
@Observable
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    var current: ToastPayload?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String, icon: String = "checkmark.circle.fill", style: InlineBanner.Style = .success, duration: Double = 2.2) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            current = ToastPayload(id: UUID(), text: text, icon: icon, style: style)
        }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self?.current = nil
            }
        }
    }
}

struct ToastPayload: Identifiable, Equatable {
    let id: UUID
    let text: String
    let icon: String
    let style: InlineBanner.Style
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .overlay(
                    Capsule().stroke(payload.style.color.opacity(0.15), lineWidth: 1)
                )
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 50)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
