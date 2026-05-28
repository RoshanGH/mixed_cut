import Foundation

/// 文件管理工具
enum FileHelper {

    /// 确保目录存在，失败时记录日志
    private static func ensureDirectory(at url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            MixLog.error("无法创建目录 \(url.path): \(error.localizedDescription)")
        }
    }

    /// 应用沙盒中的项目数据目录
    static var appSupportDirectory: URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("MixCut", isDirectory: true)
            ensureDirectory(at: fallback)
            return fallback
        }
        let url = base.appendingPathComponent("MixCut", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    // MARK: - 全局视频存储（按 hash 去重）

    /// 全局视频存储目录
    static var globalVideoDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("Videos", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 全局缩略图存储目录
    static var globalThumbnailDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 拷贝视频文件到全局目录（按 hash 子目录存储，同一视频只保留一份）
    static func copyVideoToGlobal(from sourceURL: URL, contentHash: String) throws -> URL {
        let hashDir = globalVideoDirectory.appendingPathComponent(contentHash, isDirectory: true)
        ensureDirectory(at: hashDir)
        let destURL = hashDir.appendingPathComponent(sourceURL.lastPathComponent)

        // 文件已存在则跳过（同 hash 同文件名，内容一定相同）
        if FileManager.default.fileExists(atPath: destURL.path) {
            return destURL
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    /// 删除全局视频文件（当无任何项目引用时调用）
    static func deleteGlobalVideoFiles(localPath: String, thumbnailPath: String?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: localPath) {
            // 删除文件
            try? fm.removeItem(atPath: localPath)
            // 尝试删除空的 hash 子目录
            let parentDir = (localPath as NSString).deletingLastPathComponent
            if let contents = try? fm.contentsOfDirectory(atPath: parentDir), contents.isEmpty {
                try? fm.removeItem(atPath: parentDir)
            }
        }
        if let thumbPath = thumbnailPath, fm.fileExists(atPath: thumbPath) {
            try? fm.removeItem(atPath: thumbPath)
        }
    }

    /// 临时文件目录
    static var tempDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixCut", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 删除整个项目目录（早期按项目存储时的兼容清理；新数据走全局目录但此函数保留以彻底清空老目录）
    static func deleteProjectDirectory(for projectID: UUID) {
        let projectDir = appSupportDirectory
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectDir.path) else { return }
        do {
            try FileManager.default.removeItem(at: projectDir)
        } catch {
            MixLog.error("删除项目目录失败 \(projectID): \(error.localizedDescription)")
        }
    }
}
