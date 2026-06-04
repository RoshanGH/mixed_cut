import Foundation

/// 找出"磁盘上存在但数据库已无任何记录引用"的孤儿文件（供延后删除 GC 使用）。
/// 安全原则：判断不确定时保守不删——只返回明确未被引用的。
public enum OrphanFileFinder {
    /// 归一化路径：去末尾斜杠 + 小写（macOS APFS 默认大小写不敏感）
    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.lowercased()
    }

    /// - Parameters:
    ///   - onDisk: 磁盘上扫描到的文件绝对路径
    ///   - referenced: 数据库记录引用到的路径集合
    /// - Returns: onDisk 中未被引用的路径（保持 onDisk 原始顺序与原始字符串）
    public static func orphanFiles(onDisk: [String], referenced: Set<String>) -> [String] {
        let refNorm = Set(referenced.map(normalize))
        return onDisk.filter { !refNorm.contains(normalize($0)) }
    }
}
