import SwiftUI
import AppKit

// MARK: - 学英语的网页：按"用它来干什么"分组
//
// 挑选原则：可理解输入（略高于当前水平、有上下文）+ 真人发音 + 搭配 / 学术表达。
// 在这些网站里读到好句子，直接 ⌥⌘E 划下来预览、收录——资源和句库是一个闭环。

struct LearningResource: Identifiable {
    let name: String
    let url: String
    let note: String
    var id: String { url }
}

struct ResourceGroup: Identifiable {
    let title: String
    let why: String
    let items: [LearningResource]
    var id: String { title }
}

enum LearningResources {
    static let groups: [ResourceGroup] = [
        ResourceGroup(
            title: "听力输入",
            why: "大量可理解输入：听懂 90% 以上的材料最有效，太难只是噪音",
            items: [
                LearningResource(name: "BBC Learning English", url: "https://www.bbc.co.uk/learningenglish",
                                 note: "6 Minute English 等短节目，带文稿，适合精听 + 跟读"),
                LearningResource(name: "VOA Learning English", url: "https://learningenglish.voanews.com",
                                 note: "慢速新闻，词汇受控，每篇都有音频和全文"),
                LearningResource(name: "ELLLO", url: "https://www.elllo.org",
                                 note: "各国口音的真实对话，按难度分级，附文稿和练习"),
                LearningResource(name: "TED Talks", url: "https://www.ted.com/talks",
                                 note: "可开双语字幕，医学 / 科学演讲多，适合跟读演讲节奏"),
                LearningResource(name: "British Council LearnEnglish", url: "https://learnenglish.britishcouncil.org",
                                 note: "英国文化协会出品，按等级分的听力、阅读、语法练习"),
            ]),
        ResourceGroup(
            title: "医学英语",
            why: "读自己专业的英文最有动力：先读患者版（语言平实），再读期刊（学术表达）",
            items: [
                LearningResource(name: "MedlinePlus", url: "https://medlineplus.gov",
                                 note: "美国国立医学图书馆的患者版百科，句子短、用词准，最适合入门"),
                LearningResource(name: "NIH News in Health", url: "https://newsinhealth.nih.gov",
                                 note: "NIH 每月的大众健康通讯，篇幅短，适合精读 + 临摹"),
                LearningResource(name: "NHS Health A–Z", url: "https://www.nhs.uk/conditions/",
                                 note: "英国 NHS 的疾病条目，英式用词，结构统一好对照"),
                LearningResource(name: "Mayo Clinic", url: "https://www.mayoclinic.org/diseases-conditions",
                                 note: "症状、病因、诊断、治疗分节写，临床常用表达集中"),
                LearningResource(name: "WHO Fact sheets", url: "https://www.who.int/news-room/fact-sheets",
                                 note: "世卫组织的疾病概况，数据 + 结论的写法很适合雅思小作文"),
                LearningResource(name: "MSD Manual 专业版", url: "https://www.msdmanuals.com/professional",
                                 note: "默沙东诊疗手册，临床术语的标准英文说法都在这里"),
                LearningResource(name: "NEJM", url: "https://www.nejm.org",
                                 note: "新英格兰医学杂志；Perspective 栏目是短评，比论文好读"),
                LearningResource(name: "The Lancet", url: "https://www.thelancet.com",
                                 note: "柳叶刀；Comment 与 Editorial 适合学议论文的论证句"),
                LearningResource(name: "BMJ", url: "https://www.bmj.com",
                                 note: "英国医学杂志，news 与 analysis 栏目语言更接近日常"),
                LearningResource(name: "JAMA Network", url: "https://jamanetwork.com",
                                 note: "JAMA 系列期刊；Patient Page 用一页纸讲清一个病"),
                LearningResource(name: "PubMed", url: "https://pubmed.ncbi.nlm.nih.gov",
                                 note: "论文摘要是学术写作的最好模板：背景—方法—结果—结论"),
                LearningResource(name: "STAT News", url: "https://www.statnews.com",
                                 note: "医药与生命科学新闻，行业动态的地道写法"),
                LearningResource(name: "KFF Health News", url: "https://kffhealthnews.org",
                                 note: "美国医疗政策与公共卫生报道，适合练社会类话题"),
                LearningResource(name: "Osmosis", url: "https://www.osmosis.org",
                                 note: "医学动画讲解，带字幕，适合边看边跟读专业词"),
            ]),
        ResourceGroup(
            title: "科学阅读",
            why: "雅思阅读大量取材于科普：多读这些网站，考场上题材不会陌生",
            items: [
                LearningResource(name: "Science News Explores", url: "https://www.snexplores.org",
                                 note: "写给青少年的科学新闻，难度低一档，适合打基础"),
                LearningResource(name: "Science News", url: "https://www.sciencenews.org",
                                 note: "科学新闻周刊，篇幅适中，每篇都有清楚的论点"),
                LearningResource(name: "Scientific American", url: "https://www.scientificamerican.com",
                                 note: "老牌科普杂志，科学家亲自写的长文很多"),
                LearningResource(name: "New Scientist", url: "https://www.newscientist.com",
                                 note: "英式科普周刊，句子紧凑，适合精读长难句"),
                LearningResource(name: "Science 新闻", url: "https://www.science.org/news",
                                 note: "《科学》杂志的新闻版，第一时间讲清新研究"),
                LearningResource(name: "Quanta Magazine", url: "https://www.quantamagazine.org",
                                 note: "讲数学、物理、生物的深度科普，逻辑链条清楚"),
                LearningResource(name: "Knowable Magazine", url: "https://knowablemagazine.org",
                                 note: "Annual Reviews 出品，把综述讲给普通人听"),
                LearningResource(name: "Smithsonian Magazine", url: "https://www.smithsonianmag.com",
                                 note: "科学、历史、自然，题材和雅思阅读高度重合"),
                LearningResource(name: "NASA Science", url: "https://science.nasa.gov",
                                 note: "天文、地球科学，配图丰富，句子规范"),
                LearningResource(name: "National Geographic", url: "https://www.nationalgeographic.com/science",
                                 note: "环境、动物、人类学，雅思阅读的常客题材"),
            ]),
        ResourceGroup(
            title: "科学与医学播客 / 视频",
            why: "把科学话题的听力也补上：先看文稿版读懂，再盲听",
            items: [
                LearningResource(name: "Nature Podcast", url: "https://www.nature.com/nature/podcast",
                                 note: "每周一期，研究者亲口讲自己的研究，带文稿"),
                LearningResource(name: "Science Friday", url: "https://www.sciencefriday.com",
                                 note: "美国公共广播的科学节目，访谈节奏自然"),
                LearningResource(name: "NPR Short Wave", url: "https://www.npr.org/podcasts/510351/short-wave",
                                 note: "每集十来分钟讲一个科学问题，语速友好"),
                LearningResource(name: "TED-Ed", url: "https://ed.ted.com",
                                 note: "五分钟动画课，医学、生物题材多，适合跟读"),
                LearningResource(name: "Crash Course", url: "https://thecrashcourse.com",
                                 note: "解剖生理、生物、化学系列课，语速快，适合进阶"),
            ]),
        ResourceGroup(
            title: "分级阅读",
            why: "同一内容多个难度：先读低一级建立语境，再读原文",
            items: [
                LearningResource(name: "Breaking News English", url: "https://breakingnewsenglish.com",
                                 note: "同一则新闻 7 个难度级别，附听力与练习"),
                LearningResource(name: "News in Levels", url: "https://www.newsinlevels.com",
                                 note: "三级改写的短新闻，带音频"),
                LearningResource(name: "The Conversation", url: "https://theconversation.com",
                                 note: "学者写给大众的文章，学术表达地道又好读"),
                LearningResource(name: "Nature News", url: "https://www.nature.com/news",
                                 note: "科研新闻，医学生最该积累的句型来源之一"),
            ]),
        ResourceGroup(
            title: "词典与真人发音",
            why: "查词看语境、听真人读——比只看中文释义记得牢",
            items: [
                LearningResource(name: "Cambridge Dictionary", url: "https://dictionary.cambridge.org",
                                 note: "英英释义 + 英美发音 + 大量例句"),
                LearningResource(name: "Longman (LDOCE)", url: "https://www.ldoceonline.com",
                                 note: "释义只用 2000 基础词，搭配和语域标注清楚"),
                LearningResource(name: "Oxford Learner's Dictionaries", url: "https://www.oxfordlearnersdictionaries.com",
                                 note: "学习型词典，附 Oxford 3000/5000 高频词表"),
                LearningResource(name: "YouGlish", url: "https://youglish.com",
                                 note: "输入单词或短语，播放 YouTube 上真人说它的片段"),
                LearningResource(name: "Forvo", url: "https://forvo.com",
                                 note: "母语者录制的单词发音，人名地名也有"),
                LearningResource(name: "Merriam-Webster", url: "https://www.merriam-webster.com",
                                 note: "美式权威词典，Medical 词条释义通俗"),
            ]),
        ResourceGroup(
            title: "搭配与学术写作",
            why: "学语块而不是单词：知道一个词和谁一起出现，才算会用",
            items: [
                LearningResource(name: "Ozdic 搭配词典", url: "https://ozdic.com",
                                 note: "查一个词常和哪些动词、形容词、介词搭配"),
                LearningResource(name: "Netspeak", url: "https://netspeak.org",
                                 note: "用通配符查哪种说法更常见，如 \"deprive ? of\""),
                LearningResource(name: "Academic Phrasebank", url: "https://www.phrasebank.manchester.ac.uk",
                                 note: "曼彻斯特大学整理的论文常用句型，按章节功能分类"),
                LearningResource(name: "Write & Improve", url: "https://writeandimprove.com",
                                 note: "剑桥出品，免费自动批改作文并标出问题句"),
                LearningResource(name: "Ludwig", url: "https://ludwig.guru",
                                 note: "输入半句话，找权威来源里的真实例句，判断说法是否地道"),
                LearningResource(name: "SKELL", url: "https://skell.sketchengine.eu",
                                 note: "免费语料库：查一个词的例句、搭配和近义词"),
            ]),
        ResourceGroup(
            title: "发音与口语",
            why: "先听辨再开口：重音、连读、语调比单个音更影响听感",
            items: [
                LearningResource(name: "Rachel's English", url: "https://rachelsenglish.com",
                                 note: "美音发音系统课：连读、弱读、重音讲得最细"),
                LearningResource(name: "IELTS 官网", url: "https://ielts.org",
                                 note: "官方口语 / 写作评分标准和样题"),
                LearningResource(name: "IELTS Liz", url: "https://ieltsliz.com",
                                 note: "前考官整理的各题型技巧与高分范文"),
                LearningResource(name: "BBC 发音教程", url: "https://www.bbc.co.uk/learningenglish/english/features/pronunciation",
                                 note: "BBC 的音标与连读短视频，每集只讲一个点"),
            ]),
    ]
}

struct ResourcesPane: View {
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("资源 · \(LearningResources.groups.map(\.items.count).reduce(0, +)) 个网站")
                    Text("去哪儿读、听、查")
                        .font(.system(size: 34, weight: .black)).foregroundStyle(Theme.ink)
                    Text("在这些网站读到好句子，直接 ⌥⌘E 划下来——预览、点词、跟读，满意再收录；收进来的段落可以去「临摹」打一遍。")
                        .font(.callout).foregroundStyle(Theme.dim)
                }
                // 分组多了，顶上放一排跳转
                FlowRow(spacing: 8) {
                    ForEach(LearningResources.groups) { group in
                        Button {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(group.id, anchor: .top) }
                        } label: {
                            Chip("\(group.title) · \(group.items.count)", tint: Theme.ice)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(LearningResources.groups) { group in
                    WorkbenchPanel {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(group.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                            Text(group.why).font(.caption).foregroundStyle(Theme.dim)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                                  alignment: .leading, spacing: 12) {
                            ForEach(group.items) { item in
                                ResourceCard(item: item)
                            }
                        }
                    }
                    .id(group.id)
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WorkbenchBackground())
        }
    }
}

private struct ResourceCard: View {
    let item: LearningResource
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(hovering ? Theme.ice : Theme.dim)
                }
                Text(item.note).font(.caption).foregroundStyle(Theme.dim)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(URL(string: item.url)?.host ?? item.url)
                    .font(Theme.mono(10)).foregroundStyle(Theme.ice.opacity(0.8))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(hovering ? Theme.ice.opacity(0.4) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.url)
    }
}

// MARK: - 单词卡里的外链：真人读法 + 权威词典

enum WordLinks {
    static func youglish(_ word: String) -> URL? {
        let q = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        return URL(string: "https://youglish.com/pronounce/\(q)/english/us")
    }

    static func cambridge(_ word: String) -> URL? {
        let q = word.lowercased().replacingOccurrences(of: " ", with: "-")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        return URL(string: "https://dictionary.cambridge.org/dictionary/english/\(q)")
    }

    static func ozdic(_ word: String) -> URL? {
        let q = word.lowercased().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        return URL(string: "https://ozdic.com/collocation-dictionary/\(q)")
    }
}
