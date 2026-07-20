import Foundation
import SwiftData
import AVFoundation
import CryptoKit

@MainActor
@Observable
final class DubbingViewModel {
    /// 台词变体数量：默认值与可选范围（全局设置，存 UserDefaults["dubVariantCount"]）。
    static let defaultVariantCount = 2
    static let variantCountRange = 1...5

    /// 当前要产出的台词变体数量（读全局设置，越界自动夹紧到 1...5）。
    var variantCount: Int {
        let stored = UserDefaults.standard.integer(forKey: "dubVariantCount")
        let n = stored == 0 ? Self.defaultVariantCount : stored
        return min(max(n, Self.variantCountRange.lowerBound), Self.variantCountRange.upperBound)
    }

    /// 差异化改写风格池（支持最多 5 套变体；不足时按取模复用）。
    private static let rewriteStyles = [
        "口语化、活泼带感叹词，适合年轻受众的信息流广告",
        "干练直接、强调卖点与行动号召，适合效果类信息流广告",
        "场景化讲述、先痛点后给解决方案，代入感强的信息流广告",
        "突出信任与专业、强调品质与口碑背书的信息流广告",
        "限时促销、紧迫感强、强促单转化的信息流广告"
    ]
    private static let auditionText = "这款产品真的很好用，喜欢的话点击下方链接了解一下吧。"

    let topVoices: [TTSVoice] = VoiceCatalog.top(10)

    /// 按视频独立跟踪「正在配音（克隆/改写/合成）」状态与进度——不同视频互不联动。
    var busyVideoIDs: Set<UUID> = []
    var videoProgress: [UUID: String] = [:]
    var busyDubIDs: Set<UUID> = []
    var auditioningVoiceId: String?
    var playingDubID: UUID?
    var errorMessage: String?
    /// 每个变体最近一次合成失败的友好原因（dubID → 文案），供批量汇总与单格展示。
    var lastDubErrors: [UUID: String] = [:]

    /// 该视频是否正在配音处理中（用于其专属配音条显示忙碌）。
    func isBusy(videoID: UUID?) -> Bool {
        guard let id = videoID else { return false }
        return busyVideoIDs.contains(id)
    }
    /// 该视频当前的进度文案。
    func progressText(videoID: UUID?) -> String {
        guard let id = videoID else { return "" }
        return videoProgress[id] ?? ""
    }
    private func beginBusy(_ id: UUID?) { if let id { busyVideoIDs.insert(id) } }
    private func endBusy(_ id: UUID?) { if let id { busyVideoIDs.remove(id); videoProgress[id] = nil } }
    private func setProgress(_ id: UUID?, _ text: String) { if let id { videoProgress[id] = text } }

    private let rewriteService = ScriptRewriteService()
    private let tts: TTSClient = CosyVoiceTTSClient()
    private let vcClient: TTSClient = QwenTTSClient(model: VoiceCloneService.targetModel)
    private let vocalSep = VocalSeparationService()
    private let cloneService = VoiceCloneService()
    private let finalizer = DubAudioFinalizer()
    private let asrService = ASRService()   // 逐句字幕对齐用（对成品配音做 whisper ASR 测每句时间）
    private var auditionPlayer: AVAudioPlayer?
    private var playbackResetTask: Task<Void, Never>?

    /// 该 voiceId 是否是这个视频的克隆原声。
    private func isCloned(_ voiceId: String, _ video: Video) -> Bool {
        guard let cv = video.clonedVoiceId else { return false }
        return voiceId == cv
    }

    // MARK: - 原声克隆（一键改写时自动确保已克隆）

    /// 确保该视频已克隆出原声音色（无则分离人声并注册）。返回是否就绪。
    /// 已去掉手动选音色：克隆原声就是唯一音色，落在 selectedVoiceIds=[clonedVoiceId]。
    @discardableResult
    func ensureClonedVoice(for video: Video, context: ModelContext, forceReclone: Bool = false) async -> Bool {
        let hash = video.contentHash ?? video.id.uuidString
        let fpKey = "clonedVoiceKeyFP_\(hash)"
        let currentFP = Self.currentKeyFingerprint()
        if !forceReclone, let cv = video.clonedVoiceId, !cv.isEmpty {
            // DashScope 克隆音色绑定注册它的账户(API Key)。换 Key 后旧 voiceId 在新账户不存在，
            // 合成会报 InvalidParameter。指纹能识别「装新版后克隆」的音色；存量旧音色无指纹，
            // 这里乐观复用，真失败时由 generateAllAudioWithRecloneFallback 兜底强制重克隆。
            let savedFP = UserDefaults.standard.string(forKey: fpKey)
            if currentFP == nil || savedFP == nil || savedFP == currentFP {
                if video.selectedVoiceIds != [cv] { video.selectedVoiceIds = [cv]; try? context.save() }
                return true
            }
            MixLog.info("[Clone] 检测到千问 API Key 变更，旧克隆音色(\(cv))在新账户不可用，自动重新克隆")
        } else if forceReclone {
            MixLog.info("[Clone] 强制重新克隆（合成失败自愈）")
        }
        video.clonedVoiceId = nil   // 走下方重克隆流程（能复用的已在上面 return）
        let path = video.localPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            errorMessage = "找不到原视频文件，无法克隆原声"
            return false
        }
        let vid = video.id   // 进度按此视频独立跟踪；忙碌状态由调用方管理
        MixLog.info("[Clone] 开始克隆原声: video=\(path)")
        do {
            setProgress(vid, "分离人声…")
            let stems = try await vocalSep.separate(videoPath: path, videoHash: hash) { [weak self] msg in
                Task { @MainActor in self?.setProgress(vid, msg) }
            }
            MixLog.info("[Clone] 分离完成: vocals=\(stems.vocalsPath)")
            setProgress(vid, "提取克隆参考…")
            // 参考音必须【短而干净】(≈6s)：18s 长参考含多句原话，qwen 克隆 TTS 会间歇性
            // "续读参考里的内容"导致配音混进下一段(实测 18s→clean 1/3，6s→clean 5/5)。
            let ref = try await vocalSep.referenceClip(fromVocals: stems.vocalsPath, maxSeconds: 6)
            setProgress(vid, "注册克隆音色…")
            let voiceId = try await cloneService.enroll(referenceAudioPath: ref,
                                                        preferredName: "mixcut\(hash.prefix(8))")
            MixLog.info("[Clone] 克隆成功: voiceId=\(voiceId)")
            video.clonedVoiceId = voiceId
            video.selectedVoiceIds = [voiceId]
            if let fp = currentFP { UserDefaults.standard.set(fp, forKey: fpKey) }   // 记录注册时的 Key 指纹
            try? context.save()
            setProgress(vid, "")
            return true
        } catch {
            setProgress(vid, "")
            MixLog.error("[Clone] 克隆失败: \(error.localizedDescription)")
            errorMessage = "原声克隆失败：\(Self.friendlyError(error))"
            return false
        }
    }

    // MARK: - 一键改写（自动克隆原声 → 改写 K 套台词 → 克隆配音）

    func rewriteAll(video: Video, context: ModelContext) async {
        let vid = video.id
        guard !isBusy(videoID: vid) else { return }   // 防重复点击；与其它视频互不影响
        beginBusy(vid)
        defer { endBusy(vid) }

        guard await ensureClonedVoice(for: video, context: context) else { return }
        let voices = video.selectedVoiceIds   // = [clonedVoiceId]
        guard !voices.isEmpty else { errorMessage = "克隆原声未就绪"; return }
        let reconfigurable = video.segments.filter { !$0.isVoiceLocked && !$0.text.isEmpty }
        guard !reconfigurable.isEmpty else { errorMessage = "没有可重配的分镜"; return }

        let inputs = reconfigurable.map {
            RewriteSegmentInput(segmentId: $0.id.uuidString,
                                originalText: $0.text,
                                durationSeconds: $0.duration,
                                keywords: $0.keywords)
        }
        let segById = Dictionary(uniqueKeysWithValues: reconfigurable.map { ($0.id.uuidString, $0) })

        let n = variantCount
        var completedRounds = 0
        for k in 0..<n {
            // ⚠️ 取消检查：这条链路每轮都在花钱（AI 改写 + 后续 TTS）。
            // 以前全程没有一处 Task.isCancelled，用户关掉界面也停不下来，API 继续烧。
            if Task.isCancelled {
                setProgress(vid, "")
                ToastCenter.shared.show("已停止改写，前 \(completedRounds) 套已保留", icon: "stop.circle.fill", style: .info)
                return
            }
            setProgress(vid, "改写第 \(k + 1)/\(n) 套…")
            do {
                let results = try await rewriteService.rewrite(
                    inputs: inputs,
                    style: Self.rewriteStyles[k % Self.rewriteStyles.count])
                for r in results {
                    guard let seg = segById[r.segmentId] else { continue }
                    for voiceId in voices {
                        upsertDub(segment: seg, voiceId: voiceId, textVariantIndex: k,
                                  text: r.rewrittenText, context: context)
                    }
                }
                context.saveOrWarn("改写台词")
                completedRounds += 1
            } catch {
                // ⚠️ 以前这里直接 return：已落库的前几套台词留在库里，但后面的批量合成被整体跳过，
                // 于是产生一批"有台词、没音频"的变体，用户看不出问题、也没有"只补合成"的入口。
                // 改为 break：保留已成功的几套，并继续往下走合成，把它们补齐。
                errorMessage = "第 \(k + 1) 套改写失败：\(Self.friendlyError(error))"
                if completedRounds == 0 {
                    setProgress(vid, "")
                    return   // 一套都没成功才真的中止
                }
                ToastCenter.shared.show("第 \(k + 1) 套改写失败，已保留前 \(completedRounds) 套并继续合成配音",
                                        icon: "exclamationmark.triangle.fill", style: .warning, duration: 4)
                break
            }
        }
        setProgress(vid, "")

        // 改写完成后自动批量合成 TTS（用户无需逐格手动点）；换 Key 致音色失效时自动重克隆重试
        let result = await generateAllAudioWithRecloneFallback(
            for: reconfigurable, videoID: vid, video: video, context: context)

        let producedCount = reconfigurable.count * voices.count * n
        if result.fail > 0 {
            // 弹 alert 给出真实失败原因（可截图/复制），不再只显示笼统计数
            errorMessage = Self.dubFailureMessage(
                summary: "已生成 \(producedCount) 个变体，配音合成 \(result.ok) 成功 / \(result.fail) 失败。",
                errors: result.errors)
        } else {
            ToastCenter.shared.show(
                "已生成 \(producedCount) 个配音变体并完成 TTS 合成，点开任意分镜可在右侧试听",
                icon: "checkmark.circle.fill",
                style: .success,
                duration: 3.5)
        }
    }

    // MARK: - 单分镜重新改写（改完原台词后只重出本分镜的 K 套改写 + TTS）

    func rewriteSegment(_ segment: Segment, context: ModelContext) async {
        guard let video = segment.video else { return }
        guard !segment.isVoiceLocked else { errorMessage = "该分镜保留原声，不参与配音"; return }
        guard !segment.text.isEmpty else { errorMessage = "该分镜没有原台词"; return }
        let vid = video.id
        guard !isBusy(videoID: vid) else { return }
        beginBusy(vid)
        defer { endBusy(vid) }

        guard await ensureClonedVoice(for: video, context: context) else { return }
        let voices = video.selectedVoiceIds   // = [clonedVoiceId]
        guard !voices.isEmpty else { errorMessage = "克隆原声未就绪"; return }

        let input = RewriteSegmentInput(segmentId: segment.id.uuidString,
                                        originalText: segment.text,
                                        durationSeconds: segment.duration,
                                        keywords: segment.keywords)
        let n = variantCount
        for k in 0..<n {
            setProgress(vid, "改写第 \(k + 1)/\(n) 套…")
            do {
                let results = try await rewriteService.rewrite(
                    inputs: [input],
                    style: Self.rewriteStyles[k % Self.rewriteStyles.count])
                if let r = results.first {
                    for voiceId in voices {
                        upsertDub(segment: segment, voiceId: voiceId, textVariantIndex: k,
                                  text: r.rewrittenText, context: context)
                    }
                }
                try? context.save()
            } catch {
                errorMessage = "改写失败：\(error.localizedDescription)"
                return
            }
        }
        setProgress(vid, "")

        let result = await generateAllAudioWithRecloneFallback(
            for: [segment], videoID: vid, video: video, context: context)
        if result.fail > 0 {
            errorMessage = Self.dubFailureMessage(
                summary: "本分镜已重写，配音 \(result.ok) 成功 / \(result.fail) 失败。",
                errors: result.errors)
        } else {
            ToastCenter.shared.show("本分镜已重新改写并生成配音",
                                    icon: "checkmark.circle.fill", style: .success)
        }
    }

    // MARK: - 手动新增一版（用户自己写台词 → 自动克隆配音）

    /// 在该分镜下手动新增一个空白改写版，返回新版下标（供 UI 立即进入编辑）。
    /// 自动确保已克隆原声；新建空文本变体，用户写完台词后 updateVariantText 会自动合成配音。
    @discardableResult
    func addManualVariant(for segment: Segment, context: ModelContext) async -> Int? {
        guard let video = segment.video else { return nil }
        guard !segment.isVoiceLocked else { errorMessage = "该分镜保留原声，不参与配音"; return nil }
        let vid = video.id
        guard !isBusy(videoID: vid) else { return nil }
        beginBusy(vid)
        defer { endBusy(vid) }

        guard await ensureClonedVoice(for: video, context: context) else { return nil }
        let voices = video.selectedVoiceIds   // = [clonedVoiceId]
        guard !voices.isEmpty else { errorMessage = "克隆原声未就绪"; return nil }

        let nextIndex = (segment.segmentDubs.map { $0.textVariantIndex }.max() ?? -1) + 1
        for voiceId in voices {
            upsertDub(segment: segment, voiceId: voiceId, textVariantIndex: nextIndex,
                      text: "", context: context)
        }
        try? context.save()
        return nextIndex
    }

    // MARK: - 删除某改写版（其所有音色配音 + 磁盘音频）

    /// 删除该分镜下某个改写版（含一键生成的版本）：移除所有音色的 SegmentDub 与磁盘音频文件。
    /// selectedSegmentDubId 只是 UUID 字段，消费端用 first(where:) 解析，删后自动回退原音，不会崩。
    func deleteVariant(_ segment: Segment, textVariantIndex t: Int, context: ModelContext) {
        let dubs = segment.segmentDubs.filter { $0.textVariantIndex == t }
        guard !dubs.isEmpty else { return }
        if let playing = playingDubID, dubs.contains(where: { $0.id == playing }) {
            stopDubPlayback()
        }
        for d in dubs {
            if let path = d.audioFilePath { try? FileManager.default.removeItem(atPath: path) }
            segment.segmentDubs.removeAll { $0.id == d.id }
            context.delete(d)
        }
        try? context.save()
    }

    // MARK: - 编辑某改写版台词（改完重生成该版 TTS）

    /// 把某 textVariant 下所有音色的台词改成 newText，清旧音频并重生成 TTS。
    func updateVariantText(segment: Segment, textVariantIndex t: Int,
                           newText: String, context: ModelContext) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "台词不能为空"; return }

        let dubs = segment.segmentDubs.filter { $0.textVariantIndex == t }
        guard !dubs.isEmpty else { return }
        var changed = false
        for d in dubs where d.rewrittenText != trimmed {
            d.rewrittenText = trimmed
            d.audioFilePath = nil
            d.status = .pending
            changed = true
        }
        guard changed else { return }
        try? context.save()

        guard let video = segment.video else { return }
        let vid = video.id
        beginBusy(vid)
        defer { endBusy(vid) }
        setProgress(vid, "重新合成本版配音…")
        let result = await generateAllAudioWithRecloneFallback(
            for: [segment], videoID: vid, video: video, context: context)
        setProgress(vid, "")
        if result.fail > 0 {
            errorMessage = Self.dubFailureMessage(
                summary: "台词已更新，配音 \(result.ok) 成功 / \(result.fail) 失败。",
                errors: result.errors)
        } else {
            ToastCenter.shared.show("台词已更新并重新生成配音", icon: "checkmark.circle.fill", style: .success)
        }
    }

    /// 汇总批量配音失败信息：概览 + 真实失败原因（最多列前 2 条，避免过长）+ 重试指引。
    static func dubFailureMessage(summary: String, errors: [String]) -> String {
        guard !errors.isEmpty else { return summary + "\n失败项可在分镜右侧点 ↻ 重试。" }
        let shown = errors.prefix(2).enumerated()
            .map { errors.count > 1 ? "\($0.offset + 1). \($0.element)" : $0.element }
            .joined(separator: "\n")
        let more = errors.count > 2 ? "\n…等共 \(errors.count) 类原因" : ""
        return "\(summary)\n\n失败原因：\n\(shown)\(more)\n\n失败项可在分镜右侧点 ↻ 重试。"
    }

    /// 当前千问 API Key 的指纹（SHA256 前 8 位 hex）。只存指纹不存明文，用于检测换 Key。
    static func currentKeyFingerprint() -> String? {
        guard let key = KeychainHelper.getAPIKey(for: .qwen), !key.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// 把底层（DashScope / 网络）错误翻译成用户能看懂的提示，并保留原始返回片段便于排查。
    /// 与 AI 改写共用 APIErrorClassifier 的识别规则，避免重复维护两套。
    static func friendlyError(_ error: Error) -> String {
        FriendlyError.reason(for: error)
    }

    /// qwen 克隆 TTS 偶发"续读参考内容"(合成音频比台词长、混进下一段，且常带重复)。
    /// 干净版必然最短：重试最多 3 次取最短结果；某次时长 ≤ 字数×阈值(视为干净)即提前返回。
    private static func synthesizeCloneRobust(client: TTSClient, text: String, voiceId: String) async throws -> TTSResult {
        let maxTries = 3
        let cleanLimit = Double(max(1, text.count)) * 0.28   // 秒/字上限，超过疑似跑飞
        var best: TTSResult?
        for _ in 0..<maxTries {
            let r = try await client.synthesize(text: text, voiceId: voiceId, languageType: "Chinese", rate: 1.0)
            if best == nil || r.rawDuration < best!.rawDuration { best = r }
            if r.rawDuration <= cleanLimit { break }   // 看着干净，直接用
        }
        return best!
    }

    /// 同 (分镜, 音色, 改写版) 已存在则更新文本（文本变更则清空旧音频），否则新建。
    private func upsertDub(segment: Segment, voiceId: String, textVariantIndex: Int,
                           text: String, context: ModelContext) {
        if let existing = segment.segmentDubs.first(where: {
            $0.voiceId == voiceId && $0.textVariantIndex == textVariantIndex
        }) {
            if existing.rewrittenText != text {
                existing.rewrittenText = text
                existing.audioFilePath = nil
                existing.status = .pending
            }
        } else {
            let dub = SegmentDub(segment: segment, voiceId: voiceId,
                                 textVariantIndex: textVariantIndex, rewrittenText: text)
            context.insert(dub)
            segment.segmentDubs.append(dub)
        }
    }

    // MARK: - 按需生成单格音频

    /// - Parameter silent: 批量生成时传 true，失败不逐条弹窗（由调用方汇总）。
    /// - Returns: 是否生成成功。
    @discardableResult
    func generateAudio(for dub: SegmentDub, context: ModelContext, silent: Bool = false) async -> Bool {
        guard let segment = dub.segment, let video = segment.video else { return false }
        guard !dub.rewrittenText.isEmpty else {
            if !silent { errorMessage = "该变体没有台词" }
            return false
        }
        let cloned = isCloned(dub.voiceId, video)
        // 防御：非克隆音色必须在当前 CosyVoice 目录里，否则引擎会报 418
        guard cloned || VoiceCatalog.voice(id: dub.voiceId) != nil else {
            if !silent { errorMessage = "该变体的音色已失效（旧音色），请在顶部重选音色后重新「一键改写」" }
            return false
        }
        busyDubIDs.insert(dub.id)
        defer { busyDubIDs.remove(dub.id) }
        do {
            let target = segment.duration
            let bias = video.dubSpeechRate
            // 克隆音色走 qwen-vc（无数值语速，靠 atempo 对齐）；其它走 CosyVoice + rate 对齐
            let client = cloned ? vcClient : tts
            var result: TTSResult
            if cloned {
                // qwen 克隆 TTS 间歇性"续读参考内容/跑飞"(音频比台词长，混进下一段)：
                // 干净版必然最短 → 重试取最短，看着干净(时长≤字数×阈值)即提前采用。
                result = try await Self.synthesizeCloneRobust(
                    client: client, text: dub.rewrittenText, voiceId: dub.voiceId)
            } else {
                result = try await client.synthesize(text: dub.rewrittenText, voiceId: dub.voiceId,
                                                     languageType: "Chinese", rate: 1.0)
                if let retarget = SpeechRatePlanner.retargetRate(
                    targetDuration: target, measuredDuration: result.rawDuration,
                    measuredAtRate: 1.0, bias: bias) {
                    result = try await client.synthesize(text: dub.rewrittenText, voiceId: dub.voiceId,
                                                         languageType: "Chinese", rate: retarget)
                }
            }
            let finalized = try await finalizer.finalize(
                tts: result, targetDuration: target, fps: video.fps > 0 ? video.fps : 30,
                videoHash: video.contentHash ?? video.id.uuidString,
                segmentId: segment.id, voiceId: dub.voiceId, textVariantIndex: dub.textVariantIndex)
            dub.audioFilePath = finalized.m4aPath
            dub.atempoFactor = finalized.plan.atempoFactor
            dub.freezePadFrames = finalized.plan.freezePadFrames
            dub.trailingSilence = finalized.plan.trailingSilence
            // 对齐后实际音频时长（atempo 变速后），用于在变体池展示
            dub.audioDuration = result.rawDuration / max(0.0001, finalized.plan.atempoFactor)
            dub.generatedForStartFrame = segment.startFrame
            dub.generatedForEndFrame = segment.endFrame
            dub.generatedForTextHash = DubStaleness.textHash(of: dub.rewrittenText)
            dub.status = .generated
            // TTS 已计费、音频已落盘：保存失败会变成"孤儿文件 + 必须重新付费合成"，必须告知
            context.saveOrWarn("配音")
            // 配音落库后自动逐句对齐（whisper 对成品配音测每句时间；失败静默走比例兜底，不阻断配音成功）
            await alignCaptions(for: dub, context: context)
            lastDubErrors[dub.id] = nil   // 成功后清掉旧失败原因
            return true
        } catch {
            dub.status = .failed
            try? context.save()
            let friendly = Self.friendlyError(error)
            lastDubErrors[dub.id] = friendly   // 即使 silent 也记录，供批量汇总透出
            MixLog.error("[Dub] 配音生成失败 dub=\(dub.id): \(error.localizedDescription)")
            if !silent { errorMessage = "配音生成失败：\(friendly)" }
            return false
        }
    }

    /// 逐句对齐的结局。调用方据此决定要不要给用户提示。
    enum CaptionAlignOutcome {
        /// ASR 成功，按真实词时间戳对齐
        case aligned
        /// ASR 失败，按字数比例估算（精度较差）
        case approximated(reason: String)
        /// 什么都没做，附原因
        case skipped(reason: String)
    }

    /// 对已生成配音的 dub 做逐句对齐，写回 captionLines。
    /// ASR 跑成品 m4a（已 atempo，时间=分镜内 0 起）；ASRService 是 actor，await 期间不卡主线程。
    ///
    /// - Parameter allowApproximation: ASR 失败时是否允许用「按字数比例估算」的结果覆盖现有字幕。
    ///   - 刚生成配音后的**自动**对齐传 `true`：此时 captionLines 本来就是空的，估算总比没有强。
    ///   - 用户手动点「重新自动对齐」时必须传 `false`：他可能已经逐句手调过时间，
    ///     ASR 一失败就拿估算值覆盖，等于**静默毁掉他的手工成果**且界面上毫无异样。
    @discardableResult
    func alignCaptions(for dub: SegmentDub, context: ModelContext,
                       allowApproximation: Bool = true) async -> CaptionAlignOutcome {
        guard let audio = dub.audioFilePath, FileManager.default.fileExists(atPath: audio) else {
            return .skipped(reason: "这一版还没有生成配音音频，或音频文件已丢失。请先生成配音再对齐。")
        }
        guard let seg = dub.segment else {
            return .skipped(reason: "这条配音已不属于任何分镜，无法对齐。")
        }
        let segDur = seg.duration
        guard segDur > 0 else {
            return .skipped(reason: "分镜时长为 0，无法计算字幕时间。")
        }
        guard !dub.rewrittenText.isEmpty else {
            return .skipped(reason: "这一版没有台词文本，没有可对齐的内容。")
        }

        var words: [AlignWord] = []
        var audioDur = dub.audioDuration
        var asrFailure: String?
        do {
            let r = try await asrService.transcribe(videoPath: audio)
            words = r.words.map { AlignWord(text: $0.word, start: $0.start, end: $0.end) }
            if r.duration > 0 { audioDur = r.duration }
        } catch {
            asrFailure = FriendlyError.reason(for: error)
            MixLog.info("[Caption] 逐句对齐 ASR 失败: \(error.localizedDescription)")
        }

        if let asrFailure, !allowApproximation {
            // 拿不到真实词时间戳，又不允许用估算覆盖 → 保持现状，把原因如实告诉用户
            return .skipped(reason: "语音识别没能跑通，无法精确对齐，已保留你当前的字幕时间未做改动。\n原因：\(asrFailure)")
        }

        let lines = SentenceTimingAligner.align(text: dub.rewrittenText, words: words,
                                                audioDuration: audioDur, segmentDuration: segDur)
        dub.captionLines = lines
        context.saveOrWarn("字幕时间")
        if let asrFailure {
            return .approximated(reason: asrFailure)
        }
        return .aligned
    }

    /// 批量合成一组分镜下所有「还没音频」的变体（一键改写后自动调用）。
    private func generateAllAudio(for segments: [Segment], videoID: UUID?,
                                  context: ModelContext) async -> (ok: Int, fail: Int, errors: [String]) {
        let pending = segments
            .flatMap { $0.segmentDubs }
            .filter { $0.audioFilePath == nil && !$0.rewrittenText.isEmpty }
        guard !pending.isEmpty else { return (0, 0, []) }
        var ok = 0, fail = 0
        var errors: [String] = []   // 去重收集真实失败原因，供上层透出
        for dub in pending {
            // ⚠️ 合成是整条链路里最长最贵的一段（每段都要调 TTS）。
            // 用户点了停止 / 关掉界面，必须立刻停手，不能继续烧配额。
            if Task.isCancelled {
                setProgress(videoID, "")
                MixLog.info("[Dub] 用户取消，已合成 \(ok) 段，剩余 \(pending.count - ok - fail) 段未合成")
                break
            }
            setProgress(videoID, "合成配音 \(ok + fail + 1)/\(pending.count)…")
            if await generateAudio(for: dub, context: context, silent: true) {
                ok += 1
            } else {
                fail += 1
                if let m = lastDubErrors[dub.id], !errors.contains(m) { errors.append(m) }
            }
        }
        setProgress(videoID, "")
        return (ok, fail, errors)
    }

    /// 判断批量失败是否为「克隆音色失效」（多因更换 API Key，旧克隆音色在新账户不存在）。
    static func isStaleCloneError(_ errors: [String]) -> Bool {
        errors.contains { e in
            let l = e.lowercased()
            return l.contains("tts speak request failed")
                || (l.contains("invalidparameter") && l.contains("voice"))
                || l.contains("克隆音色在当前 api key")
        }
    }

    /// 批量合成；若失败是「克隆音色失效」，自动用当前 Key 强制重克隆、把待生成变体迁到新音色后重试一次。
    /// 覆盖指纹无法识别的存量旧音色：乐观复用→真失败→自愈重克隆，用户无感；没换 Key 则永不触发。
    private func generateAllAudioWithRecloneFallback(
        for segments: [Segment], videoID vid: UUID?, video: Video, context: ModelContext
    ) async -> (ok: Int, fail: Int, errors: [String]) {
        let first = await generateAllAudio(for: segments, videoID: vid, context: context)
        guard first.fail > 0, Self.isStaleCloneError(first.errors) else { return first }
        guard let oldVoice = video.clonedVoiceId else { return first }

        setProgress(vid, "检测到克隆音色失效，正在用当前 Key 重新克隆…")
        guard await ensureClonedVoice(for: video, context: context, forceReclone: true),
              let newVoice = video.clonedVoiceId, newVoice != oldVoice else {
            return first   // 重克隆失败 → 保留原始错误供展示
        }
        // 把这些分镜下「待生成且仍指向旧克隆音色」的变体迁到新音色（已生成的本地文件不动）
        for seg in segments {
            for dub in seg.segmentDubs where dub.audioFilePath == nil && dub.voiceId == oldVoice {
                dub.voiceId = newVoice
                dub.status = .pending
            }
        }
        try? context.save()
        setProgress(vid, "重克隆完成，重新合成配音…")
        let retry = await generateAllAudio(for: segments, videoID: vid, context: context)
        setProgress(vid, "")
        return retry
    }

    // MARK: - 试听已生成的变体音频（对齐后的成片音频）

    /// 播放某个变体已生成的音频文件（再次点击同一变体则停止）。
    func playDub(_ dub: SegmentDub) {
        if playingDubID == dub.id { stopDubPlayback(); return }
        guard let path = dub.audioFilePath, FileManager.default.fileExists(atPath: path) else {
            errorMessage = "音频文件不存在，请重新生成该变体"
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            auditionPlayer = player
            player.play()
            playingDubID = dub.id
            // 播完自动复位高亮（AVAudioPlayer 的 delegate 需要 NSObject，这里用时长定时复位更简单）
            playbackResetTask?.cancel()
            let duration = max(0.1, player.duration)
            playbackResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if self?.playingDubID == dub.id { self?.playingDubID = nil }
            }
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
        }
    }

    func stopDubPlayback() {
        playbackResetTask?.cancel()
        playbackResetTask = nil
        auditionPlayer?.stop()
        auditionPlayer = nil
        playingDubID = nil
    }

    // MARK: - 导出前补齐选定变体音频

    /// 对方案里被选中但还没音频的变体按需补齐合成（导出前调用）。
    func ensureSelectedAudio(for scheme: MixScheme, context: ModelContext) async {
        for ss in scheme.orderedSegments {
            guard let id = ss.selectedSegmentDubId,
                  let dub = ss.segment?.segmentDubs.first(where: { $0.id == id }),
                  dub.audioFilePath == nil else { continue }
            await generateAudio(for: dub, context: context)
        }
    }

    // MARK: - 试听音色样例

    func audition(voiceId: String, rate: Double = 1.0, cloned: Bool = false) async {
        auditioningVoiceId = voiceId
        defer { auditioningVoiceId = nil }
        do {
            let client = cloned ? vcClient : tts
            let result = try await client.synthesize(text: Self.auditionText, voiceId: voiceId,
                                                     languageType: "Chinese", rate: rate)
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: result.wavPath))
            auditionPlayer = player
            player.play()
        } catch {
            errorMessage = "试听失败：\(Self.friendlyError(error))"
        }
    }
}
