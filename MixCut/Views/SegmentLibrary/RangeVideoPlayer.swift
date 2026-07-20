import SwiftUI
import AVKit

/// 悬停播放某视频指定区间 [startTime,endTime] 的轻量播放器（解耦 Segment）。
/// 工作区分镜头轨道 / 版本卡复用；靠外部 `playingID` 做本地单播（同一时刻只一个在播）。
struct RangeVideoPlayer: View {
    let videoPath: String
    let startTime: Double
    let endTime: Double
    let fps: Double
    let thumbnailPath: String?
    let playID: UUID
    @Binding var playingID: UUID?

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var isHovering = false

    private var isActive: Bool { playingID == playID }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black)
            if isActive, let player {
                ShotPlayerLayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let t = thumbnailPath, let img = ThumbnailCache.shared.image(for: t) {
                Image(nsImage: img).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "film").font(.title3).foregroundStyle(.white.opacity(0.6))
            }
        }
        // hover 挂最外层容器（非条件分支），避免鼠标移到另一卡片卡住不切
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                playingID = playID
                startPlayback()
            } else {
                stopPlayback()
                if playingID == playID { playingID = nil }
            }
        }
        .onChange(of: playingID) { _, newValue in
            if newValue != playID { stopPlayback() }   // 别的卡开播 → 停我
        }
        .onDisappear { stopPlayback() }
    }

    private func startPlayback() {
        guard player == nil,
              !videoPath.isEmpty, FileManager.default.fileExists(atPath: videoPath) else { return }
        let item = AVPlayerItem(url: URL(fileURLWithPath: videoPath))
        let halfFrame = fps > 0 ? 0.5 / fps : 0.01
        item.forwardPlaybackEndTime = CMTime(seconds: max(0, endTime - halfFrame), preferredTimescale: 600)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        // 到结尾定格：不清 playingID（否则 onChange 会把定格帧清回缩略图，见 SegmentInlinePlayer 的坑）
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in /* 停在最后一帧 */ }
        p.seek(to: CMTime(seconds: startTime + halfFrame, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        player = p
        p.play()
    }

    private func stopPlayback() {
        player?.pause()
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player = nil
    }
}

/// 无控件、填满（resizeAspectFill）的播放视图——去掉 AVKit VideoPlayer 的控件 chrome 与黑边。
private struct ShotPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.showsFullScreenToggleButton = false
        v.videoGravity = .resizeAspectFill   // 9:16 填满容器，无黑边
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
