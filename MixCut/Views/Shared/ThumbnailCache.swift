import AppKit
import SwiftUI

/// 全局缩略图缓存（NSCache，自动响应内存压力）
///
/// 用 NSCache 而非 Dictionary：
/// - countLimit / totalCostLimit 自动 eviction
/// - 系统内存压力时自动清理
/// - 多 view 共享，避免重复加载
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300                    // 最多 300 张缩略图
        c.totalCostLimit = 150 * 1024 * 1024  // 总 150MB
        return c
    }()

    private init() {}

    /// 同步取缩略图（已缓存就返回，未缓存就加载并缓存）
    func image(for path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        let cost = Int(img.size.width * img.size.height * 4)
        cache.setObject(img, forKey: key, cost: cost)
        return img
    }

    /// 预热：异步预加载（后台线程读磁盘，主线程入缓存）
    func prewarm(paths: [String]) {
        Task.detached(priority: .utility) {
            for path in paths {
                if FileManager.default.fileExists(atPath: path) {
                    if let img = NSImage(contentsOfFile: path) {
                        await MainActor.run {
                            let key = path as NSString
                            if self.cache.object(forKey: key) == nil {
                                let cost = Int(img.size.width * img.size.height * 4)
                                self.cache.setObject(img, forKey: key, cost: cost)
                            }
                        }
                    }
                }
            }
        }
    }

    func clear() { cache.removeAllObjects() }
}
