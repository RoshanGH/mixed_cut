import Foundation
import SwiftData

extension ModelContext {
    /// 安全保存，失败时记录日志而非静默吞掉错误
    func safeSave(file: String = #file, line: Int = #line) {
        do {
            try save()
        } catch {
            let fileName = (file as NSString).lastPathComponent
            MixLog.error("数据库保存失败 [\(fileName):\(line)]: \(error.localizedDescription)")
        }
    }
}
