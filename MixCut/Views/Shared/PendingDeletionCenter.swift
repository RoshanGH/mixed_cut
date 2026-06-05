import SwiftUI

/// 延迟删除中心 —— 商业 to C 软件的「撤销浮条」模式（剪映 / Gmail「撤回」同款）。
///
/// 删除时：调用方先在**界面上隐藏**该项（从 @Observable 数组 / 关系里移除），并登记一对
/// `commit`（真正落库删除）/ `undo`（放回界面）闭包。宽限期（5 秒）内点浮条「撤销」→ 取消真删、
/// 执行 undo 放回；不点 → 到点执行 commit 真正删除。
///
/// 关键：**永不依赖 SwiftData 内置 UndoManager**（它一挂删除就崩）。恢复是「放回」而非「重建」，
/// 因为宽限期内对象根本没被真删，最可靠。
///
/// 同一时刻只维护一个 pending：新的删除/切项目/数据重载前会先把上一个 pending `flushNow()`（真删），
/// 避免「界面隐藏但数据库未删」在重载后又冒出来的不一致。
@MainActor
@Observable
final class PendingDeletionCenter {
    static let shared = PendingDeletionCenter()
    private init() {}

    /// 宽限期秒数（撤销浮条停留时长）
    static let graceSeconds: Double = 5

    @ObservationIgnored private var pendingCommit: (() -> Void)?
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    /// 登记一次延迟删除。调用方需在调用前已把该项从界面隐藏。
    /// - Parameters:
    ///   - message: 浮条文案（如「已删除分镜」）
    ///   - commit: 宽限期结束或被 flush 时执行——真正 `context.delete` + 保存
    ///   - undo: 点「撤销」时执行——把隐藏的项放回界面
    func schedule(message: String, commit: @escaping () -> Void, undo: @escaping () -> Void) {
        // 先提交上一个 pending（保证同一时刻只有一个），避免堆叠
        flushNow()
        pendingCommit = commit
        timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.graceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pendingCommit?()
            self?.pendingCommit = nil
            self?.timerTask = nil
        }
        ToastCenter.shared.show(message, icon: "trash.fill", style: .warning,
                                duration: Self.graceSeconds,
                                actionTitle: "撤销") { [weak self] in
            self?.undoPending(undo)
        }
    }

    /// 点「撤销」：取消真删 + 放回界面
    private func undoPending(_ undo: () -> Void) {
        timerTask?.cancel()
        timerTask = nil
        pendingCommit = nil
        undo()
    }

    /// 立即提交当前 pending（真正删除）。在切项目 / 数据重载 / 退出前调用，
    /// 避免「界面已隐藏但数据库未删」在重载后又显示出来。无 pending 时是空操作。
    func flushNow() {
        timerTask?.cancel()
        timerTask = nil
        pendingCommit?()
        pendingCommit = nil
    }
}
