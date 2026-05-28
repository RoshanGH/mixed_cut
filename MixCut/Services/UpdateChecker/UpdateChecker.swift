import Foundation
import SwiftUI
import AppKit

/// 版本检查 - 双端容灾：优先 GitHub，超时/失败 fallback 到 Gitee
actor UpdateChecker {
    struct ReleaseInfo: Sendable {
        let tag: String          // "v0.3.1"
        let version: String      // "0.3.1"（去掉 v 前缀）
        let htmlURL: URL
        let source: Source

        enum Source: String, Sendable { case github, gitee }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private struct GiteeRelease: Decodable {
        let tagName: String
        // Gitee 没有 html_url 字段，需要从仓库 + tag 拼
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    private let githubURL = URL(string: "https://api.github.com/repos/RoshanGH/mixed_cut/releases/latest")!
    private let giteeURL = URL(string: "https://gitee.com/api/v5/repos/jinxiushanhehao/mixed_cut/releases/latest")!
    private let giteeReleasePagePrefix = "https://gitee.com/jinxiushanhehao/mixed_cut/releases/tag/"
    private let timeout: TimeInterval = 5.0

    /// 主接口：返回最新 release（GitHub 优先）；都失败返回 nil
    func fetchLatest() async -> ReleaseInfo? {
        if let info = await tryGitHub() { return info }
        return await tryGitee()
    }

    private func tryGitHub() async -> ReleaseInfo? {
        var req = URLRequest(url: githubURL, timeoutInterval: timeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let r = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                  let url = URL(string: r.htmlURL) else { return nil }
            let version = stripV(r.tagName)
            return ReleaseInfo(tag: r.tagName, version: version, htmlURL: url, source: .github)
        } catch {
            return nil
        }
    }

    private func tryGitee() async -> ReleaseInfo? {
        var req = URLRequest(url: giteeURL, timeoutInterval: timeout)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let r = try? JSONDecoder().decode(GiteeRelease.self, from: data) else { return nil }
            let version = stripV(r.tagName)
            guard let url = URL(string: giteeReleasePagePrefix + r.tagName) else { return nil }
            return ReleaseInfo(tag: r.tagName, version: version, htmlURL: url, source: .gitee)
        } catch {
            return nil
        }
    }

    private func stripV(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// 语义化版本比较：remote 是否比 local 更新
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        let maxLen = max(r.count, l.count)
        for i in 0..<maxLen {
            let ri = i < r.count ? r[i] : 0
            let li = i < l.count ? l[i] : 0
            if ri > li { return true }
            if ri < li { return false }
        }
        return false
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class UpdateCheckerViewModel {
    var latestInfo: UpdateChecker.ReleaseInfo?
    var hasUpdate: Bool = false
    /// 用户主动 dismiss 过的版本 → 不再显示 banner
    private var dismissedVersion: String {
        get { UserDefaults.standard.string(forKey: "dismissedUpdateVersion") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "dismissedUpdateVersion") }
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private let checker = UpdateChecker()

    /// 启动时调一次（不阻塞 UI）
    func checkSilently() {
        Task { [weak self] in
            guard let self else { return }
            guard let info = await self.checker.fetchLatest() else { return }
            let isNewer = UpdateChecker.isNewer(info.version, than: self.currentVersion)
            let notDismissed = info.version != self.dismissedVersion
            self.latestInfo = info
            self.hasUpdate = isNewer && notDismissed
        }
    }

    /// 用户点「稍后再说」隐藏 banner（仅这次版本不再提示）
    func dismissCurrentBanner() {
        if let v = latestInfo?.version { dismissedVersion = v }
        hasUpdate = false
    }

    /// 用户点「立即更新」打开浏览器
    func openReleasePage() {
        guard let url = latestInfo?.htmlURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - UI Banner

struct UpdateBanner: View {
    @Bindable var viewModel: UpdateCheckerViewModel

    var body: some View {
        if viewModel.hasUpdate, let info = viewModel.latestInfo {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                Text("发现新版本")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                Text("v\(viewModel.currentVersion) → v\(info.version)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.18))
                    .clipShape(Capsule())

                Text("(\(info.source == .github ? "GitHub" : "Gitee"))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                Button {
                    viewModel.openReleasePage()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                        Text("立即下载更新")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white)
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.dismissCurrentBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("不再提示此版本")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color.purple, Color.blue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}
