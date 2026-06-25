# 分镜画面裂变(换背景)— VACE 打样分析与初步设计

> 日期:2026-06-24
> 分支:`feature/new-task`(隔离 worktree)
> 状态:**打样完成,结论已定,正式 spec 待写**

---

## 1. 目标与背景

为 MixCut 增加**第三个视频裂变维度**——对单个分镜做画面替换(第一版只做**换背景**):

- 维度1(已有):原分镜排列组合 → 不同剪辑顺序
- 维度2(另一 session 在做):台词改写 + 克隆原声 + 重烧字幕 → 声音/文案裂变
- **维度3(本设计):单分镜换背景** → 画面裂变,主体动作/产品核心不变
- 维度4(未来):BGM 替换

**产品形态(已与用户对齐的 5 个决策):**
1. 人物可略变,只要"像同一个人、动作对上" → 接受重生成式编辑
2. AI 自动识别当前背景 + 给几个**同类候选**(微调,不给太多自主权)
3. 第一版**只做换背景**(换人物以后再说)
4. 只允许 **≤5 秒**的分镜换背景(超过的置灰)
5. **先出便宜的图片预览选定,再花钱跑视频**

---

## 2. 关键事实(已联网+实测确认)

### 2.1 "Happy House" 澄清
用户/同事说的"Happy House"≈"Happy Horse(快乐马)",是阿里 2026 年的**视频生成大模型**(文生/图生视频),**不能**做"保留现有分镜动作只换背景",方向不对。真正对应需求的是**通义万相 VACE 视频编辑模型**。

### 2.2 VACE 接口(北京区,已实测跑通)
- **模型 ID:`wanx2.1-vace-plus`**(注意:北京区是 `wanx2.1-`,新加坡区才是 `wan2.1-`;某调研一度纠错成 wan2.1 是错的)
- 创建任务:`POST https://dashscope.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis`
- 查询:`GET https://dashscope.aliyuncs.com/api/v1/tasks/{task_id}`
- 必需头:`Authorization: Bearer KEY`、`Content-Type: application/json`、`X-DashScope-Async: enable`;用 `oss://` 素材再加 `X-DashScope-OssResourceResolve: enable`
- 鉴权 key **复用现有千问 DashScope key**(同属 DashScope)
- 本地视频→URL:DashScope 临时上传(`GET /uploads?action=getPolicy&model=...` → form-data POST 到 `upload_host` → 得 `oss://` URL,48h 有效)

### 2.3 输入/输出硬约束(实测)
| 项 | 值 |
|---|---|
| 输入视频 | MP4,≥16fps,**≤5 秒**,≤50MB,边长 [360,2000] |
| 输出 | 720p、30fps、**无声**、MP4 |
| **<5 秒输入的时长行为** | **输出时长 = 输入时长(不拉伸!)** — 实测 3.2s 输入→3.23s 输出/97 帧。"固定5秒"只在输入≥5s 时发生。**→ 原声可直接合回,时长对齐** |
| 异步 | 任务 ~2 分钟完成;结果 URL **24h 过期**,拿到立即下载落本地 |

### 2.4 换背景的两种 function 与遮罩语义
- `video_repainting`(整片重绘):会动前景,**不适合保产品**
- `video_edit`(局部编辑):用遮罩**保前景换背景**
- 遮罩颜色:**白(255,255,255)=要重画的区域;黑(0,0,0)=保留不变** → 背景涂白、前景涂黑
- 遮罩可传 `mask_image_url`(单张图,推荐)+ `mask_frame_id` + `parameters.mask_type:"tracking"`(随运动跟踪),或 `mask_video_url`(逐帧)
- 遮罩图必须与输入视频**同分辨率**

---

## 3. 四条路线实测对比(用真实滴露厨房灶台分镜 3.2s)

| 路线 | 产品品牌 | 背景质量 | 前景动作 | 工程成本 | 结论 |
|---|---|---|---|---|---|
| **depth 整片重绘** | ❌ 绿瓶→杂牌银瓶 | 风格化不真实 | ✓ 保 | 低 | **广告不可用** |
| **单帧PNG遮罩 + tracking** | ✅ **保住绿瓶** | ✅ 好(明亮新厨房) | ⚠️ 只跟刚性主体,丢复杂手部动作 | Vision 原生抠图,**无需打包重模型** | ✅ **可用主路** |
| 逐帧遮罩视频(tv色域) | ❌ 前景被抹空 | — | — | 高 | ❌ 失败 |
| 逐帧遮罩视频(pc无损色域) | ❌ 前景仍被抹空 | — | — | 高 | ❌ 再次失败,非色域问题,`mask_video_url` 行为不明,**v1 放弃** |

**遮罩生成方案(关键利好):** macOS 原生 `VNGenerateForegroundInstanceMaskRequest`(Vision 框架,"抠主体"那套)逐帧/单帧抠前景→反相+阈值成"前景黑/背景白"遮罩,**不打包任何外部模型**,契合"开箱即用"原则。实测单帧抠"手+喷雾瓶"很准。

---

## 4. 结论与推荐架构

**功能可行。主路 = `video_edit` + macOS Vision 单帧抠图遮罩 + `mask_type:tracking`。**

- 能换出漂亮新厨房背景、**保住产品品牌**、抠图用系统原生能力。
- **最适合"前景稳定"镜头(人站着讲话/产品展示)= 用户主场景。**
- **已知边界**:剧烈articulated手部动作(如快速擦拭)单帧遮罩跟不住;逐帧遮罩视频路线实测不可靠 → v1 不做,作为未来增强。

### 推荐落地流程(7 步,复用现有 TTS/FFmpeg 异步骨架)
1. 选分镜(≤5s)→ 2. AI 视觉识别当前背景 + 生成同类候选提示词 → 3. 对**首帧**跑便宜图像编辑出候选缩略图 → 4. 用户挑一张 → 5. Vision 抠首帧遮罩 + 上传视频/遮罩 → 6. `video_edit` 跑 VACE(异步轮询)→ 7. 裁回原时长 + 合回原声,存为该分镜的**「画面变体」**(原分镜不动)

### 推荐组件(对标现有 DubVariant 范式)
- `WanxImageEditClient`(actor):首帧候选缩略图(`wanx2.1-imageedit`,~0.14元/张)
- `WanxVaceClient`(actor):提交→轮询→下载,复用 FFmpegRunner 异步/取消模式
- `DashScopeUploadClient`:临时上传拿 oss:// URL
- `SceneDetectService`:视觉模型识别背景+生成候选提示词
- `ForegroundMaskService`:Vision 抠图生成遮罩(macOS 原生)
- `SegmentVisualVariant`(@Model,对标 DubVariant):不可变,原 Segment 永不被改
- `BackgroundSwapViewModel` + `BackgroundSwapSheet`(9:16 预览)
- 入口:SegmentCard 右键菜单加「换背景」,>5s 置灰
- 落盘:`AppSupport/MixCut/VisualVariants/{segmentId}/{variantId}.mp4`

### 计费(待控制台确认精确单价)
- 图像编辑预览:~0.14 元/张
- VACE 视频:按输出秒数计费,官方文档跳价格页未给确定数,需控制台实测

---

## 5. 打样产物位置
- 脚本/素材/结果:本会话 scratchpad(`vace_spike*.sh`、`make_mask*.swift`、`orig_segment.mp4`、`vace_out.mp4`/`vace_edit_out.mp4`/`vace_mv_out.mp4`、对照图 `compare_all.png` 等)
- 注:VACE 结果 URL 24h 过期,本地 mp4 已落地

---

## 6. 下一步
正式 spec(走 spec 评审)→ writing-plans 实现计划。**当前因用户切换到另一需求(分镜时长筛选条件)而暂缓。**
