# PRD 04 · 逐句字幕时间对齐与烧录（Windows 端毫米级对齐）

> 对齐目标：**macOS 版 v0.8.0**。本文档给出 Windows 端完整复现所需的**数据模型 / 对齐算法 / 编辑器交互 / 联动分界数学 / 导出烧录**的精确规格。看图 + 编号表可快速理解，落地时以本文各章节的数值/公式为准。

---

## 0. 一句话与背景

**问题**：一条逻辑分镜生成的"配音变体"里，字幕以前是**整段一次性**烧在画面上（一进画面就把整段台词全堆上去），观众无法"听到哪句、看到哪句"。

**目标**：让变体的字幕**按每一句实际被说出的时间逐句出现**——第 1 句说完才出第 2 句，字幕跟着人声走。

**范围（重要，先划清边界）**：
- 逐句字幕**只作用于"配音变体"**（有改写台词 + 有克隆配音的那种变体）。
- **锁定原声的分镜**（keepOriginalAudio / voiceLocked）**不烧逐句字幕**。
- **没有配音的变体**（没走到配音那步）**不烧**。
- 变体台词里**标点已被去掉**（烧录时也会再去一次），不显示标点。
- 对齐 = **自动生成为主 + 手动微调兜底**；两者都要有。

---

## 1. 界面总览（红色编号对应下表）

入口：分镜素材库 → 某条分镜的**变体检视器（SegmentVariantInspector）** → 该变体若已生成配音，出现「**逐句字幕**」按钮（图标 `captions.bubble`）→ 点开下图弹窗。

![逐句字幕时间编辑器](https://raw.githubusercontent.com/RoshanGH/mixed_cut/main/docs/screenshots/caption-editor-annotated.png)

### 编号 → 控件 → 功能

| # | 控件 | 功能 / 规格 |
|---|------|------|
| 1 | 标题区（「逐句字幕时间」+ 副标题） | 副标题格式：`改写版 A · 分镜时长 10.8s`。A/B/C… = 该变体的 `textVariantIndex`（0→A，1→B…）；分镜时长 = 该逻辑分镜时长，一位小数。 |
| 2 | 关闭 | 关闭弹窗。**所有时间修改是即时写库的**（每次 ± 立即保存），关闭不需要"保存"，也不会撤销。 |
| 3 | 每句左侧播放按钮（▶ 绿 / ■ 红） | **试听这一句配音**：从该句 `起` 播到 `止` 后自动停。播放中图标变红方块，再点=停止。同一时刻只播一句。 |
| 4 | 句子文本（只读） | 该句的**原始文本**（含标点，仅供人读；烧录时会去标点）。**不可在此编辑文字**——要改字得去改这版台词（见 ⑨）。 |
| 5 | 「起」时间步进（− 值 ＋） | 该句**开始时间**（相对分镜起点，秒，一位小数）。**「起」= 与上一句之间的分界**。−/＋ 每次 **0.1s**。 |
| 6 | 「止」时间步进（− 值 ＋） | 该句**结束时间**。**「止」= 与下一句之间的分界**。−/＋ 每次 **0.1s**。 |
| 7 | 相邻两句的分界（第 i 句「止」= 第 i+1 句「起」，同一条线） | **联动分界**：拖动这条分界，两句的**字会按各自时间在两句之间迁移/合并**。详见 §4。 |
| 8 | 重新自动对齐（✨） | 用该变体配音**重新识别每句时间**、覆盖手动调过的值（**文本不变**）。点击弹二次确认「重新对齐（覆盖当前时间）／取消」。 |
| 9 | 底部提示 | 文案：`字幕文字要改？去改这版台词（会重新配音并重新对齐）`。表明：改文字不在这里做，改台词会触发重新配音 + 重新对齐。 |

### 精确尺寸 / 外观

- 弹窗固定 **460 × 560 pt**，圆角 12，浅色（强制 aqua，不跟随深色模式）。
- 结构：Header（padding 12）→ Divider → 可滚动句子列表（padding 14，句间距 8）→ Divider → Footer（padding 12）。
- 每句卡：圆角 8，`controlBackgroundColor` 底 + 0.5pt 分隔线描边；播放中底色不透明度 0.9，否则 0.5。
- 播放按钮：`title3` 字号；绿=`play.circle.fill`，红=`stop.circle.fill`。
- 时间值：等宽字体，宽 44pt 居中，格式 `%.1fs`。步进 −/＋ 为 borderless small 按钮。
- 列表为空时中间显示「还没有逐句字幕数据」或对齐中显示「正在对齐…」。

---

## 2. 数据模型（持久化）

每个"配音变体"（SegmentDub）新增一个字段 `captionLines`，随变体存库：

```
CaptionLine {
  text:  String        // 该句原文（含标点；导出与显示各自去标点）
  start: Double         // 起（相对分镜起点，秒）
  end:   Double         // 止（相对分镜起点，秒）
  chars: [TimedChar]    // 该句每个字的时间（供编辑器联动分界用；导出不用）
}
TimedChar {
  ch:  String           // 单个字
  end: Double           // 该字"结束时间"（相对分镜起点，秒）
}
```

- **持久化格式**：JSON，随 SegmentDub 一起存（macOS 用 `captionLinesData: Data?` + JSON 编解码）。Windows 用等价的可空 blob/JSON 列即可。
- `chars` 里每个字只存 `end`（结束时间）；某字的"开始"= 上一个字的 `end`（首字的开始 = 句子的 `start`）。这样一串 `end` 递增序列就完整表达了逐字时间轴。
- **导出只用 `text/start/end`**；`chars` 仅编辑器"联动分界"用。旧数据没有 `chars` 时按整句 `text` 在 `[start,end]` 内**均匀合成**一份（见 §4.1 兜底）。

---

## 3. 自动对齐算法（核心，必须逐字复现）

> 输入：这版**改写台词全文** `text`、这版**配音的 ASR 词级时间**（`words: [{text,start,end}]`，来自对配音音频跑一次语音识别）、配音时长 `audioDuration`、分镜时长 `segmentDuration`。
> 输出：`[CaptionLine]`（每句 `text/start/end` + 逐字 `chars`）。

### 3.1 切句

按**句末标点/换行**切句，句末符集合：`。！？!?.;；\n`。

- 逐字符累加到当前句缓冲；遇到句末符就断句。
- 断句时对缓冲**去标点/空白**后若非空才收录（纯标点段丢弃）；收录的句子**保留原文**（含内部非句末标点，如逗号）。
- 去标点/空白字符集（用于**计数与匹配**，不改变收录的原文）：`，,、。！？!?.;；（空格）\n\r\t…·：:`。
- 全部切完若一句都没有 → 返回空（不烧字幕）。

### 3.2 主策略：按字数比例分配到"语音跨度"

- **语音跨度** `[spanStart, spanEnd]`：有 ASR 词时 = `[首词.start, 末词.end]`；无词时 = `[0, audioDuration]`（`spanEnd` 至少比 `spanStart` 大 0.01）。
- 每句权重 = 该句**去标点字符数**（至少 1）。按累计字数占比把 `[spanStart, spanEnd]` **线性切分**给各句：

```
counts[i] = max(1, 去标点字数(句i));  total = Σ counts
acc = 0
for i in 句:
    a = spanStart + (spanEnd-spanStart) * acc / total
    acc += counts[i]
    b = spanStart + (spanEnd-spanStart) * acc / total
    line[i] = { text: 句i, start: a, end: b }
```

### 3.3 精修：用 ASR 逐字匹配（有 words 时）

把 ASR 的词展开成**字符级时间轴** `tl = [(字, 字start, 字end)]`：一个多字词的 `[start,end]` 按字数**线性内插**到每个字。

> **数字折叠（关键）**：构建 `tl` 的每个字、以及每句待匹配字符，都要把**阿拉伯数字折成中文单字**：`0→〇 1→一 2→二 … 9→九`。这样台词「69」→「六九」，能与 ASR 念出的「六十九」逐字匹配（匹配时允许跳过 ASR 里多出来的「十」）。**不折叠会导致数字句匹配失败**（这是修复前"某句时间塌成 0"的根因之一）。

逐句在 `tl` 上**贪心顺序匹配**，用一个全局指针 `ptr` 保证句子按顺序推进：

```
ptr = 0
for i in 句:
    sc = 折叠(去标点字符(句i))
    j = ptr; matched = 0; startT = nil; endT = nil
    while j < tl.len and matched < sc.len:
        if tl[j].字 == sc[matched]:
            if matched == 0: startT = tl[j].字start
            endT = tl[j].字end
            matched += 1
        j += 1
    if startT!=nil and endT!=nil and matched >= max(1, sc.len/2):
        mStart[i] = startT
        mEnd[i]   = max(startT + 0.05, endT)   // 匹配成功=锚点
        ptr = j
    // 否则 mStart[i]/mEnd[i] 保持 nil（本句匹配失败）
```

- 只有**匹配到过半字符**（`matched ≥ 句字数/2`，至少 1）才算成功、才更新 `ptr`。失败句不消耗指针。

### 3.4 失败句插值（关键，杜绝"零宽度句"）

匹配失败的句子**绝不保留 §3.2 的旧比例值**（否则会与已精修的邻居打架、被挤成零宽度而**在成片里完全不显示**）。做法：把**连续失败**的一段句子，放到**前后最近的锚点之间按字数插值**：

```
spanStart = 首词.start（无词则用首句 start 或 0）
spanEnd   = 末词.end（无词则用末句 end）
i = 0
while i < n:
    if 句i 有锚点(mStart[i]!=nil): line[i] = 锚点; i += 1; continue
    // 收集连续失败段 [i, k)
    k = i; while k<n and mStart[k]==nil: k += 1
    leftAnchor  = (i>0 ? mEnd[i-1] : spanStart)
    rightAnchor = (k<n ? mStart[k] : spanEnd)
    width = max(0.0001, rightAnchor - leftAnchor)
    // 段内按去标点字数比例切 [leftAnchor, rightAnchor]
    counts = [max(1, 字数(句s)) for s in i..k]; total = Σ counts; acc = 0
    for s in i..k:
        line[s].start = leftAnchor + width*acc/total
        acc += counts[s对应count]
        line[s].end   = leftAnchor + width*acc/total
    i = k
```

### 3.5 归一化 + 逐字时间

**归一化**（保证单调、不越界、不重叠、非零）：按 `start` 排序后逐句：

```
start = clamp(start, 0, segmentDuration)
end   = clamp(max(start+0.05, end), start+0.05, segmentDuration)
if i>0 and start < prev.end: start = prev.end     // 不与上一句重叠
if end < start: end = start + 0.05
```

**逐字时间**：对每句，把去标点后的字**在 `[start,end]` 内按字数均匀**分布，写入 `chars`：

```
n = 字数; span = max(0.001, end-start)
chars[k].ch  = 第k个字
chars[k].end = start + span * (k+1)/n     // k 从 0 起
```

> 即：句边界由 ASR/插值决定，句**内**按字数均匀。这份 `chars` 就是编辑器"联动分界"的依据。

### 3.6 触发时机

- **自动**：每次给变体**生成/重生成配音**成功后（`audioFilePath` 落库那一刻）自动跑一次对齐，写回 `captionLines`。**失败静默兜底**（走 §3.2 比例，不阻断"配音成功"）。
- **手动**：编辑器 ⑧「重新自动对齐」按钮再跑一次（覆盖手调值，文本不变）。
- ASR 用的是**该变体自己的配音音频**（不是原视频、不上传视频）。

---

## 4. 编辑器交互：时间微调 + 联动分界（毫米级）

### 4.1 「起 / 止」步进的语义

- 「起」= 与**上一句**的分界；「止」= 与**下一句**的分界。**同一条分界被两句共享**（第 i 句的「止」≡ 第 i+1 句的「起」）。
- 因此调时间**不是**改单句的两个独立数字，而是**移动分界**——分界一动，跨界的**字要在相邻两句之间迁移/合并**。这就是"联动"。
- **首句的「起」** 没有上一句 → 只 clamp 自己：`clamp(v, 0, 止-0.05)`。
- **末句的「止」** 没有下一句 → 只 clamp 自己：`clamp(v, 起+0.05, 分镜时长)`。
- 其余「起/止」都走 §4.2 的 `moveBoundary`。

取某句逐字时间 `charsOf(line)`：有 `chars` 直接用；旧数据无 `chars` → 按整句 `text` 在 `[start,end]` **均匀合成**一份（与 §3.5 同式）。

### 4.2 moveBoundary（联动分界的唯一真源，务必逐行复现）

移动"第 i 句与第 i+1 句之间的分界"到时间 `t`（`minGap = 0.05`）：

```
moveBoundary(lines, i, t):
  if i<0 or i+1>=len(lines): return 原样        // 越界不动
  b = clamp(t, lines[i].start + minGap, lines[i+1].end)   // 分界范围
  merged = charsOf(lines[i]) + charsOf(lines[i+1])         // 两句字按时间升序拼接
  if merged 空: return 原样
  left  = [c in merged if c.end <= b + 0.0005]             // 结束时间≤分界 → 归左句
  right = [c in merged if c.end >  b + 0.0005]             // 其余 → 归右句
  if right 空:                     // 分界推到/超过右句末 → 右句被吃满
      lines[i].chars = merged; lines[i].text = 拼字(merged); lines[i].end = lines[i+1].end
      删除 lines[i+1]              // ★合并删除：右句整句并入左句
  else if left 空:                 // 分界压到首字之前 → 会掏空左句
      return 原样                  // ★绝不掏空左句：保持当前分区不动
  else:
      lines[i].chars   = left;  lines[i].text   = 拼字(left);  lines[i].end   = b
      lines[i+1].chars = right; lines[i+1].text = 拼字(right); lines[i+1].start = b
  return lines
```

- `起(i)` 调用 `moveBoundary(_, i-1, v)`；`止(i)` 调用 `moveBoundary(_, i, v)`。
- **每次修改即时写库**。

### 4.3 三条铁律（必须一致）

1. **字总量守恒、顺序不变**：字只在相邻两句间迁移，从不新增/丢失/乱序。
2. **右句吃满即删除**：把第 i 句的「止」一路加大，第 i+1 句的字被逐个并入第 i 句；当分界盖过第 i+1 句的末字，第 i+1 句**整句消失**、并入第 i 句。
3. **绝不掏空左句**：若某次拖动会让左句一个字都不剩，则**保持原分区不动**（该操作视为无效）。

### 4.4 联动分界 · 演算示例（务必用它做验收）

初始两句（逐字时间见括号）：

```
句1「你好」 起0.0 止1.0   chars: 你(0.5) 好(1.0)
句2「世界」 起1.0 止2.0   chars: 世(1.5) 界(2.0)
```

- **把句1「止」+ 到 1.5**（= `moveBoundary(i=0, t=1.5)`）：merged = 你(0.5) 好(1.0) 世(1.5) 界(2.0)；分界 b=1.5 → left=你好世、right=界。
  结果：`句1「你好世」起0.0 止1.5`、`句2「界」起1.5 止2.0`。（句2 首字"世"迁入句1）
- **继续把句1「止」+ 到 2.0**：right 为空 → **句2 被吃满删除**。
  结果：`句1「你好世界」起0.0 止2.0`（只剩一句）。
- **反向：从初始两句把句1「止」− 到 0.5**：left=你、right=好世界。
  结果：`句1「你」起0.0 止0.5`、`句2「好世界」起0.5 止2.0`。（"好"迁回句2）
- **把句1「止」− 到 0.2（< 首字"你"的 0.5）**：left 空 → **原样不动**（不掏空左句）。

---

## 5. 导出：逐句烧录（单条 + 批量都走同一渲染）

### 5.1 何时烧

- **只烧配音变体**：`isVoiceLocked == false` **且** `captionLines` 非空，才烧。
- 锁定原声段、无配音变体 → `captionLines = []`，**不烧**。
- **旧数据兜底**：变体有配音但 `captionLines` 为空（老数据没对齐过）→ 用整段台词兜一条 `CaptionLine(text: 整段, start: 0, end: 分镜时长)`，等价旧的"整段烧法"，**防止老变体丢字幕**。

### 5.2 逐句渲染

- **每句一张 PNG**：把该句 `text` **去标点**（去标点集同 §3.1）后渲染成透明底/半透明底的字幕图（macOS 用系统字体渲染 PNG，1× 像素，避免 Retina 2×；Windows 用等价方式生成每句 PNG 或直接用带 `enable` 的字幕滤镜）。空串跳过。
- **时间窗**：第 li 张图用 `overlay=x:y:enable='between(t, line.start, line.end)'` 只在该句时间窗显示。**`t` 是分镜内部 0 基时间**（导出时对每个分镜做了 `trim,setpts=PTS-STARTPTS`，所以 `t` 从 0 起，正好对上 `captionLines` 的相对时间）。
- **链式叠加**：多句 PNG 依次链式 overlay（`[masked][cap0]→[c0]`, `[c0][cap1]→[c1]`, …），得到逐句依次出现的效果。
- **字号**：按成片宽度自适应的全局档位（与"字幕字号"设置一致）。
- **位置**：字幕画布宽 = 遮挡区宽（下限 120px，防止逐字竖排）；落点由统一的字幕布局函数按成片宽高 + 遮挡矩形算出（底部居中区）。
- **去标点后为空**的句子不出图。

### 5.3 与遮挡/配音链路的关系

- 逐句 PNG 作为**额外输入**先于 dub/bgm 音频追加，输入序号自然排布。
- 锁定段/无配音（keepOriginalAudio）分支**不产生任何字幕输入**。
- 单条导出（DubExportService）与批量导出（VariantBatchExportService）**共用同一 `renderSegment`**，两条链路烧录行为完全一致。

---

## 6. 验收清单（Windows 端自测）

**自动对齐**
- [ ] 生成一条含数字（如"69元/9.9包邮"）的多句配音变体 → 打开逐句字幕：**每句都有非零时长**、时间**依次不重叠**、单调递增（无某句塌成 0）。
- [ ] 台词里的阿拉伯数字句能被正确卡到其被念出的时间窗（数字折叠生效）。
- [ ] 重生成配音后，逐句时间自动更新。

**编辑器**
- [ ] ③ 点某句播放，只播该句 `[起,止]` 后自动停；再点停止；换句会切。
- [ ] ⑤⑥ ± 每次动 0.1s，即时生效、关闭再开仍在。
- [ ] 首句「起」下限 0、末句「止」上限=分镜时长。
- [ ] ⑧ 重新自动对齐弹二次确认；确认后时间被覆盖、文本不变。

**联动分界（按 §4.4 演算逐条验收）**
- [ ] 加大某句「止」→ 下一句的字**逐个并入**该句、下一句「起」同步右移。
- [ ] 一直加到盖过下一句「止」→ 下一句**整句消失**、并入本句。
- [ ] 反向减小 → 字**迁回**下一句。
- [ ] 减到首字之前 → **原样不动**（不掏空左句）。

**导出**
- [ ] 真导出一条配音变体成片：字幕**逐句出现**、**去标点**、**卡在被说的时间窗**内。
- [ ] 锁定原声段 / 无配音变体：**不烧**字幕。
- [ ] 老变体（未对齐过）：仍按整段兜底烧出（不丢字幕）。
- [ ] 单条导出与批量导出结果一致；分镜首帧不黑屏。

---

## 7. 对应的 macOS 源码（供 Windows 侧参考实现，不必逐行照抄）

- 数据模型：`Sources/MixCutCore/CaptionLine.swift`（`CaptionLine` / `TimedChar`）
- 自动对齐：`Sources/MixCutCore/SentenceTimingAligner.swift`（切句/比例/数字折叠/ASR 匹配/失败插值/归一化/逐字时间）
- 联动分界：`Sources/MixCutCore/CaptionBoundaryEditor.swift`（`moveBoundary` / `charsOf` 纯函数，含单测）
- 编辑器 UI：`MixCut/Views/SegmentLibrary/CaptionTimingEditorSheet.swift`
- 导出烧录：`MixCut/Services/Export/DubExportService.swift`（`renderSegment` 逐句 overlay）、`VariantBatchExportService.swift`
- 单测：`Tests/MixCutCoreTests/SentenceTimingAlignerTests.swift`、`CaptionBoundaryEditorTests.swift`（含 §4.4 全部用例）
