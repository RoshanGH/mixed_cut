import SwiftUI
import AVKit

/// 原地视频播放器：缩略图态 ↔ 播放态 切换，自带可拖动进度条
struct InlineVideoPlayer: View {
    let videoPath: String
    let thumbnailPath: String?
    let aspectRatio: CGFloat

    @State private var isPlaying = false
    @State private var player: AVPlayer?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isSeeking = false
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 0) {
            if isPlaying, let player {
                // 视频画面
                PlayerRepresentable(player: player)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // 自定义控制栏
                controlBar(player: player)
            } else {
                thumbnailView
                    .overlay {
                        Button {
                            startPlayback()
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.3), radius: 4)
                        }
                        .buttonStyle(.plain)
                    }
            }
        }
        .onDisappear {
            stopPlayback()
        }
    }

    // MARK: - 控制栏（进度条 + 按钮）

    private func controlBar(player: AVPlayer) -> some View {
        HStack(spacing: 6) {
            // 播放/暂停
            Button {
                if player.timeControlStatus == .playing {
                    player.pause()
                } else {
                    player.play()
                }
            } label: {
                Image(systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)

            // 当前时间
            Text(formatTime(currentTime))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            // 可拖动进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 3)

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: progressWidth(in: geo.size.width), height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isSeeking = true
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            currentTime = fraction * duration
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            let targetTime = CMTime(seconds: fraction * duration, preferredTimescale: 600)
                            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                            isSeeking = false
                        }
                )
            }
            .frame(height: 16)

            // 总时长
            Text(formatTime(duration))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)

            // 停止按钮
            Button {
                stopPlayback()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return totalWidth * CGFloat(currentTime / duration)
    }

    // MARK: - 缩略图

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbPath = thumbnailPath,
           let image = NSImage(contentsOfFile: thumbPath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - 播放控制

    private func startPlayback() {
        let url = URL(fileURLWithPath: videoPath)
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        isPlaying = true

        // 获取总时长
        if let item = newPlayer.currentItem {
            Task {
                let dur = try? await item.asset.load(.duration)
                if let dur {
                    await MainActor.run {
                        duration = CMTimeGetSeconds(dur)
                    }
                }
            }
        }

        // 定时更新当前播放时间
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if !isSeeking {
                currentTime = CMTimeGetSeconds(time)
            }
        }

        newPlayer.play()

        // 播放结束自动停止
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { _ in
            stopPlayback()
        }
    }

    private func stopPlayback() {
        if let observer = timeObserver, let p = player {
            p.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
            endObserver = nil
        }
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

/// 纯画面播放视图（无内建控件）
struct PlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
