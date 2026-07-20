import Foundation
import SwiftData

extension ModelContext {
    /// 安全保存，失败时记录日志而非静默吞掉错误。
    @discardableResult
    func safeSave(file: String = #file, line: Int = #line) -> Bool {
        do {
            try save()
            return true
        } catch {
            let fileName = (file as NSString).lastPathComponent
            MixLog.error("数据库保存失败 [\(fileName):\(line)]: \(error.localizedDescription)")
            return false
        }
    }

    /// 保存并在失败时告知用户。
    ///
    /// ⚠️ 用于「改动很贵或很难重做」的场景（重识别台词、已计费的配音产物、合成结果等）：
    /// 这些地方以前是 `try? save()` 紧跟一句成功提示 —— 保存失败时用户仍看到"成功"，
    /// 重启后改动却消失了，属于最难排查的一类问题。
    /// - Returns: 是否保存成功；调用方据此决定是否弹成功提示。
    @MainActor
    @discardableResult
    func saveOrWarn(_ whatFailed: String, file: String = #file, line: Int = #line) -> Bool {
        if safeSave(file: file, line: line) { return true }
        ToastCenter.shared.show("\(whatFailed)保存失败，改动可能在重启后丢失。请重试或导出诊断日志反馈。",
                                icon: "exclamationmark.triangle.fill", style: .warning, duration: 5)
        return false
    }
}
