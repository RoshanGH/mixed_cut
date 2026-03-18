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

    // MARK: - 旧版按项目存储（保留用于数据迁移）

    /// 视频存储目录（旧版按项目）
    static func videoDirectory(for projectID: UUID) -> URL {
        let url = appSupportDirectory
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Videos", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 缩略图存储目录（旧版按项目）
    static func thumbnailDirectory(for projectID: UUID) -> URL {
        let url = appSupportDirectory
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 导出目录
    static func exportDirectory(for projectID: UUID) -> URL {
        let url = appSupportDirectory
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 拷贝文件到项目目录（旧版，保留用于数据迁移）
    static func copyVideoToProject(from sourceURL: URL, projectID: UUID) throws -> URL {
        let destDir = videoDirectory(for: projectID)
        let destURL = destDir.appendingPathComponent(sourceURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    /// 临时文件目录
    static var tempDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixCut", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 删除整个项目目录（视频 + 缩略图 + 导出文件）
    static func deleteProjectDirectory(for projectID: UUID) {
        let projectDir = appSupportDirectory
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: projectDir)
        } catch {
            MixLog.error("删除项目目录失败 \(projectID): \(error.localizedDescription)")
        }
    }

    /// 删除单个视频文件及其缩略图（旧版，保留兼容）
    static func deleteVideoFiles(localPath: String, thumbnailPath: String?) {
        deleteGlobalVideoFiles(localPath: localPath, thumbnailPath: thumbnailPath)
    }

    /// 创建 Security-Scoped Bookmark
    static func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// 从 Bookmark 恢复 URL 访问
    static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale { return nil }
        return url
    }
}
