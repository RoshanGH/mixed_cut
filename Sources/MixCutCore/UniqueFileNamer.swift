import Foundation

/// 在已有文件名集合中为新文件找一个不冲突的名字："歌.mp3" → "歌 2.mp3" → "歌 3.mp3"…
public enum UniqueFileNamer {
    public static func uniqueName(for fileName: String, existing: Set<String>) -> String {
        guard existing.contains(fileName) else { return fileName }
        let ns = fileName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }
}
