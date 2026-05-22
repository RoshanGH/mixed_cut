import SwiftUI

/// 通用的内联提示 banner（替代分散在各页面的自制错误条）
/// - 自动淡入淡出
/// - 用户可点 x 关闭，也可点重试（如果传了 onRetry）
struct InlineBanner: View {
    enum Style {
        case error, warning, info, success

        var iconName: String {
            switch self {
            case .error:   return "exclamationmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info:    return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .error:   return .red
            case .warning: return .orange
            case .info:    return .blue
            case .success: return .green
            }
        }
    }

    let style: Style
    let message: String
    var onRetry: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var autoDismissAfter: Double? = nil   // 秒数；nil = 不自动消失

    init(style: Style, message: String, onDismiss: (() -> Void)? = nil, autoDismissAfter: Double? = nil) {
        self.style = style
        self.message = message
        self.onDismiss = onDismiss
        self.autoDismissAfter = autoDismissAfter
    }

    init(style: Style, message: String, onRetry: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.style = style
        self.message = message
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.iconName)
                .font(.system(size: 13))
                .foregroundStyle(style.color)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onRetry {
                Button("重试", action: onRetry)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.color)
            }

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(style.color.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(style.color.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .transition(.move(edge: .top).combined(with: .opacity))
        .task(id: message) {
            // 如果设置了自动消失，倒计时后调用 onDismiss
            guard let after = autoDismissAfter, let onDismiss else { return }
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.25)) {
                    onDismiss()
                }
            }
        }
    }
}
