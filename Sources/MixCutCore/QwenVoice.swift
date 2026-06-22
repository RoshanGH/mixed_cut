import Foundation

/// 千问 qwen3-tts-flash 系统音色。
public struct QwenVoice: Equatable, Sendable, Identifiable {
    public let id: String          // voice 参数值，如 "Cherry"
    public let displayName: String // 中文名，如 "芊悦"
    public let summary: String     // 音色特点
    public let dialect: String?    // 方言（普通话音色为 nil）

    public init(id: String, displayName: String, summary: String, dialect: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.dialect = dialect
    }
}

/// 全部系统音色目录（供 Settings 列表 + 试听 + 最多选 3）。
public enum QwenVoiceCatalog {
    public static let all: [QwenVoice] = [
        QwenVoice(id: "Cherry", displayName: "芊悦", summary: "阳光积极、亲切自然小姐姐"),
        QwenVoice(id: "Serena", displayName: "苏瑶", summary: "温柔小姐姐"),
        QwenVoice(id: "Ethan", displayName: "晨煦", summary: "标准普通话带部分北方口音，阳光温暖有活力"),
        QwenVoice(id: "Chelsie", displayName: "千雪", summary: "二次元虚拟女友"),
        QwenVoice(id: "Momo", displayName: "茉兔", summary: "撒娇搞怪，逗你开心"),
        QwenVoice(id: "Vivian", displayName: "十三", summary: "拽拽的、可爱的小暴躁"),
        QwenVoice(id: "Moon", displayName: "月白", summary: "率性帅气的月白"),
        QwenVoice(id: "Maia", displayName: "四月", summary: "知性与温柔的碰撞"),
        QwenVoice(id: "Kai", displayName: "凯", summary: "耳朵的一场SPA"),
        QwenVoice(id: "Nofish", displayName: "不吃鱼", summary: "不会翘舌音的设计师"),
        QwenVoice(id: "Bella", displayName: "萌宝", summary: "喝酒不打醉拳的小萝莉"),
        QwenVoice(id: "Jennifer", displayName: "詹妮弗", summary: "品牌级、电影质感般美语女声"),
        QwenVoice(id: "Ryan", displayName: "甜茶", summary: "节奏拉满，戏感炸裂"),
        QwenVoice(id: "Katerina", displayName: "卡捷琳娜", summary: "御姐音色，韵律回味十足"),
        QwenVoice(id: "Aiden", displayName: "艾登", summary: "精通厨艺的美语大男孩"),
        QwenVoice(id: "Eldric Sage", displayName: "沧明子", summary: "沉稳睿智的老者"),
        QwenVoice(id: "Mia", displayName: "乖小妹", summary: "温顺如春水，乖巧如初雪"),
        QwenVoice(id: "Mochi", displayName: "沙小弥", summary: "聪明伶俐的小大人"),
        QwenVoice(id: "Bellona", displayName: "燕铮莺", summary: "声音洪亮，吐字清晰"),
        QwenVoice(id: "Vincent", displayName: "田叔", summary: "沙哑烟嗓，江湖豪情"),
        QwenVoice(id: "Bunny", displayName: "萌小姬", summary: "萌属性爆棚的小萝莉"),
        QwenVoice(id: "Neil", displayName: "阿闻", summary: "字正腔圆的专业新闻主持人"),
        QwenVoice(id: "Elias", displayName: "墨讲师", summary: "把复杂知识讲清楚的讲师"),
        QwenVoice(id: "Arthur", displayName: "徐大爷", summary: "被岁月浸泡过的质朴嗓音"),
        QwenVoice(id: "Nini", displayName: "邻家妹妹", summary: "又软又黏的甜嗓"),
        QwenVoice(id: "Seren", displayName: "小婉", summary: "温和舒缓助眠声线"),
        QwenVoice(id: "Pip", displayName: "顽屁小孩", summary: "调皮捣蛋充满童真"),
        QwenVoice(id: "Stella", displayName: "少女阿月", summary: "甜到发腻的迷糊少女音"),
        QwenVoice(id: "Bodega", displayName: "博德加", summary: "热情的西班牙大叔"),
        QwenVoice(id: "Sonrisa", displayName: "索尼莎", summary: "热情开朗的拉美大姐"),
        QwenVoice(id: "Alek", displayName: "阿列克", summary: "战斗民族的冷与暖"),
        QwenVoice(id: "Dolce", displayName: "多尔切", summary: "慵懒的意大利大叔"),
        QwenVoice(id: "Sohee", displayName: "素熙", summary: "温柔开朗的韩国欧尼"),
        QwenVoice(id: "Ono Anna", displayName: "小野杏", summary: "鬼灵精怪的青梅竹马"),
        QwenVoice(id: "Lenn", displayName: "莱恩", summary: "理性底色叛逆细节的德国青年"),
        QwenVoice(id: "Emilien", displayName: "埃米尔安", summary: "浪漫的法国大哥哥"),
        QwenVoice(id: "Andre", displayName: "安德雷", summary: "声音磁性、沉稳男生"),
        QwenVoice(id: "Radio Gol", displayName: "拉迪奥·戈尔", summary: "用名字解说足球的足球诗人"),
        QwenVoice(id: "Jada", displayName: "上海-阿珍", summary: "风风火火的沪上阿姐", dialect: "上海话"),
        QwenVoice(id: "Dylan", displayName: "北京-晓东", summary: "北京胡同里长大的少年", dialect: "北京话"),
        QwenVoice(id: "Li", displayName: "南京-老李", summary: "耐心的瑜伽老师", dialect: "南京话"),
        QwenVoice(id: "Marcus", displayName: "陕西-秦川", summary: "面宽话短、心实声沉的老陕味道", dialect: "陕西话"),
        QwenVoice(id: "Roy", displayName: "闽南-阿杰", summary: "诙谐直爽的台湾哥仔", dialect: "闽南语"),
        QwenVoice(id: "Peter", displayName: "天津-李彼得", summary: "天津相声专业捧哏", dialect: "天津话"),
        QwenVoice(id: "Sunny", displayName: "四川-晴儿", summary: "甜到心里的川妹子", dialect: "四川话"),
        QwenVoice(id: "Eric", displayName: "四川-程川", summary: "跳脱市井的成都男子", dialect: "四川话"),
        QwenVoice(id: "Rocky", displayName: "粤语-阿强", summary: "幽默风趣的阿强", dialect: "粤语"),
        QwenVoice(id: "Kiki", displayName: "粤语-阿清", summary: "甜美的港妹闺蜜", dialect: "粤语"),
    ]
}
