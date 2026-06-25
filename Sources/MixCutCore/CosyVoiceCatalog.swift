import Foundation

/// DashScope cosyvoice-v2 系统音色目录（仅普通话子集；广告/带货人设排前 10）。
/// 顶部「配音设置」默认展示 `all.prefix(10)`，其余供后续搜索/全列表扩展。
public enum CosyVoiceCatalog {
    /// 适配 cosyvoice-v2 的模型标识。
    public static let model = "cosyvoice-v2"

    public static let all: [TTSVoice] = [
        // —— 前 10：信息流广告/带货人设 ——
        TTSVoice(id: "longyingxiao", displayName: "龙樱晓", summary: "甜美带货女主播，亲和有感染力"),
        TTSVoice(id: "longanchong", displayName: "龙安宠", summary: "激情四射的带货销售男"),
        TTSVoice(id: "longanxuan", displayName: "龙安璇", summary: "经典女主播，专业稳定"),
        TTSVoice(id: "longanping", displayName: "龙安萍", summary: "高音直播女，热场带节奏"),
        TTSVoice(id: "longxiaochun_v2", displayName: "龙小淳", summary: "知性积极女，干净自然"),
        TTSVoice(id: "longanrou", displayName: "龙安柔", summary: "温柔闺蜜女，贴心种草"),
        TTSVoice(id: "longanyun", displayName: "龙安耘", summary: "居家暖心男，亲切可信"),
        TTSVoice(id: "longyichen", displayName: "龙逸尘", summary: "洒脱活力男，年轻有冲劲"),
        TTSVoice(id: "longhua_v2", displayName: "龙华", summary: "活力甜美女，元气满满"),
        TTSVoice(id: "longanlang", displayName: "龙安朗", summary: "清新干净男，清爽利落"),

        // —— 其余普通话音色（按性别/风格分布，供扩展）——
        TTSVoice(id: "longanli", displayName: "龙安丽", summary: "清脆沉稳女"),
        TTSVoice(id: "longanwen", displayName: "龙安雯", summary: "优雅知性女"),
        TTSVoice(id: "longanqin", displayName: "龙安琴", summary: "亲和活泼女"),
        TTSVoice(id: "longanya", displayName: "龙安雅", summary: "优雅高贵女"),
        TTSVoice(id: "longanling", displayName: "龙安灵", summary: "思维敏捷女"),
        TTSVoice(id: "longanran", displayName: "龙安然", summary: "活泼有质感女"),
        TTSVoice(id: "longanshuo", displayName: "龙安朔", summary: "干净清爽男"),
        TTSVoice(id: "longanzhi", displayName: "龙安之", summary: "睿智成熟青年男"),
        TTSVoice(id: "longyumi_v2", displayName: "YUMI", summary: "严肃年轻女"),
        TTSVoice(id: "longxiaoxia_v2", displayName: "龙小夏", summary: "沉稳权威女"),
        TTSVoice(id: "longwanjun", displayName: "龙婉君", summary: "细腻轻柔女"),
        TTSVoice(id: "longbaizhi", displayName: "龙白芷", summary: "睿智旁白女"),
        TTSVoice(id: "longmiao_v2", displayName: "龙淼", summary: "抑扬顿挫女"),
        TTSVoice(id: "longyue_v2", displayName: "龙玥", summary: "温暖磁性女"),
        TTSVoice(id: "longyuan_v2", displayName: "龙媛", summary: "温暖治愈女"),
        TTSVoice(id: "longxing_v2", displayName: "龙馨", summary: "邻家温柔女"),
        TTSVoice(id: "longwan_v2", displayName: "龙菀", summary: "积极知性女"),
        TTSVoice(id: "longfeifei_v2", displayName: "龙菲菲", summary: "甜美细腻女"),
        TTSVoice(id: "longyan_v2", displayName: "龙嫣", summary: "温暖柔和女"),
        TTSVoice(id: "longqiang_v2", displayName: "龙嫱", summary: "浪漫魅力女"),
        TTSVoice(id: "loongbella_v2", displayName: "Bella 2.0", summary: "精准干练女"),
        TTSVoice(id: "loongstella_v2", displayName: "Stella", summary: "清脆高效女"),
        TTSVoice(id: "longxiaobai_v2", displayName: "龙小白", summary: "沉稳播音女"),
        TTSVoice(id: "longjing_v2", displayName: "龙婧", summary: "标准女主播"),
        TTSVoice(id: "longnan_v2", displayName: "龙楠", summary: "睿智青年男"),
        TTSVoice(id: "longcheng_v2", displayName: "龙澄", summary: "睿智青年男"),
        TTSVoice(id: "longhan_v2", displayName: "龙翰", summary: "温暖深情男"),
        TTSVoice(id: "longxiaocheng_v2", displayName: "龙小诚", summary: "磁性低音男"),
        TTSVoice(id: "longzhe_v2", displayName: "龙喆", summary: "冷面暖心男"),
        TTSVoice(id: "longtian_v2", displayName: "龙天", summary: "磁性理性男"),
        TTSVoice(id: "longze_v2", displayName: "龙泽", summary: "温暖活力男"),
        TTSVoice(id: "longshao_v2", displayName: "龙韶", summary: "积极向上男"),
        TTSVoice(id: "longhao_v2", displayName: "龙昊", summary: "深情忧郁男"),
        TTSVoice(id: "longfei_v2", displayName: "龙飞", summary: "热情磁性男"),
        TTSVoice(id: "longjin_v2", displayName: "龙瑾", summary: "优雅温和男"),
        TTSVoice(id: "longshu_v2", displayName: "龙澍", summary: "沉稳青年男"),
        TTSVoice(id: "longshuo_v2", displayName: "龙烁", summary: "博学干练男"),
        TTSVoice(id: "longsanshu", displayName: "龙三叔", summary: "沉稳儒雅男"),
        TTSVoice(id: "longxiu_v2", displayName: "龙修", summary: "博学说书男"),
        TTSVoice(id: "longanpei", displayName: "龙安佩", summary: "年轻教师女"),
        TTSVoice(id: "longhuhu", displayName: "龙呼呼", summary: "天真活泼女孩"),
        TTSVoice(id: "longniuniu", displayName: "龙妞妞", summary: "阳光男孩"),
        TTSVoice(id: "longke_v2", displayName: "龙可", summary: "天真乖巧女孩"),
        TTSVoice(id: "longxian_v2", displayName: "龙娴", summary: "大胆可爱女"),
        TTSVoice(id: "longling_v2", displayName: "龙铃", summary: "童稚冷面女"),
        TTSVoice(id: "longjielidou_v2", displayName: "龙杰力豆", summary: "阳光顽皮男孩"),
        TTSVoice(id: "longlaobo", displayName: "龙老伯", summary: "沧桑老者男"),
        TTSVoice(id: "longlaoyi", displayName: "龙老姨", summary: "世故阿姨女"),
        TTSVoice(id: "longgaoseng", displayName: "龙高僧", summary: "得道高僧男"),
        TTSVoice(id: "longdaiyu", displayName: "龙黛玉", summary: "灵秀才女"),
        TTSVoice(id: "longjixin", displayName: "龙吉心", summary: "毒舌伶俐女"),
        TTSVoice(id: "longjiqi", displayName: "龙吉奇", summary: "萌呆机器人男"),
        TTSVoice(id: "longhouge", displayName: "龙猴哥", summary: "经典美猴王男"),
        TTSVoice(id: "libai_v2", displayName: "李白", summary: "古风诗人男"),
        TTSVoice(id: "kabuleshen_v2", displayName: "龙神", summary: "才华歌手男"),
        TTSVoice(id: "longshanshan", displayName: "龙闪闪", summary: "戏剧童声女"),
        TTSVoice(id: "longyingmu", displayName: "龙樱木", summary: "优雅知性女"),
        TTSVoice(id: "longyingda", displayName: "龙樱达", summary: "开朗高音女"),
        TTSVoice(id: "longyingtian", displayName: "龙樱恬", summary: "温柔甜美女"),
        TTSVoice(id: "longyingtao", displayName: "龙樱桃", summary: "温柔沉稳女"),
        TTSVoice(id: "longyingling", displayName: "龙樱铃", summary: "温柔共情女"),
        TTSVoice(id: "longyingjing", displayName: "龙樱静", summary: "低调沉稳女"),
        TTSVoice(id: "longyingyan", displayName: "龙樱岩", summary: "正气严厉女"),
        TTSVoice(id: "longyingbing", displayName: "龙樱冰", summary: "犀利果断女"),
        TTSVoice(id: "longyingxun", displayName: "龙樱勋", summary: "青涩年轻男"),
        TTSVoice(id: "longyingcui", displayName: "龙樱崔", summary: "严肃催收男"),
    ]
}

/// 当前生效的 TTS 音色目录与查询入口（现为 CosyVoice）。
/// 视图/VM 一律走这里，换模型时只改这一处。
public enum VoiceCatalog {
    /// 当前生效目录（全部音色）。
    public static var active: [TTSVoice] { CosyVoiceCatalog.all }

    /// 顶部默认展示的前若干音色。
    public static func top(_ n: Int) -> [TTSVoice] { Array(active.prefix(n)) }

    /// 按 voiceId 查音色（找不到返回 nil）。
    public static func voice(id: String) -> TTSVoice? {
        active.first { $0.id == id }
    }

    /// 按 voiceId 查显示名（找不到回退原 id）。
    public static func displayName(id: String) -> String {
        voice(id: id)?.displayName ?? id
    }
}
