# 第二阶段 UI 概念图

由内置 image_gen 生成，属于目标设计预览，不代表功能已经实现。示例人物、照片与文字均为虚构。

## 信息架构

- 对话：文字、图片、短视频、语音、引用回复、表情回应；快捷轻互动保持独立。
- 愿望：愿望及其生命周期、随机提醒、按类别组织的双人清单。
- 回忆：照片、收藏消息、实现的愿望和完成的清单；按时间组织，保留来源链接。
- 我们：沿用第一组的周期、关系信息、设备与隐私设置，升级为四个底部入口。

媒体沿用原始设计的设备间加密传输方向；异步等待应明确，不暗示服务器存有可随时下载的照片。时间胶囊不纳入这组第二阶段设计。

## 图片

- conversation-media.png：丰富消息及附件选择面板。
- wishes-checklists.png：愿望与双人清单。
- memories.png：回忆时间线与详情。

## 视觉审阅与实施修正

这些图片用于比较整体布局，不能逐像素照搬。需要统一四个导航图标，使用同一套字体、间距和无障碍对比度规范。

- 等待对方上线时使用静态等待状态，不能使用有数值含义的进度条；实际传输才显示进度。
- 当前“进行中”筛选下不显示已实现卡片。概念图同时展示两种卡片仅说明视觉样式；实施时采用正确筛选或独立“全部”。
- 附件面板里的多余或不准确生成文字应替换成确定的产品文案，例如“写下一个愿望”。
- 回忆来源是双方共享数据；自动归档设置、手工收藏、撤销与删除语义需要明确并验证。
- 照片只在用户主动选取或拍摄后附加，愿望卡片不能依赖自动生成插图。

## 完整提示词

### 1

Use case: ui-mockup. A refined final-product UI design presentation for a private Chinese iPhone couples app 我们, stage two. Landscape canvas showing TWO full front-facing iPhone screens side by side, identical scale, complete top status bars and bottom safe areas, very thin dark phone frames. Warm off-white backdrop. Screens warm ivory #F8F5EF, dark readable Chinese sans-serif text, muted terracotta #B86552 accents and soft sage green. Native implementable iOS 18 controls, generous but useful whitespace, sophisticated quiet intimate design. NO decorative slogans outside phones, NO loud gradients, NO excessive hearts, NO debug controls. Both phones have identical FOUR bottom tabs with thin consistent icons: 对话 / 愿望 / 回忆 / 我们. All screens have realistic readable Chinese text, accessible contrast. Not a social network, no follower counts, no streaks, no public feed. Asset: messaging and media concept board. LEFT phone 对话 selected. Header 我们 small lock icon, no back arrow. Today divider. Left message 晚霞好漂亮. Right photo bubble showing candid Mediterranean coastal sunset with a discreet small 收藏 icon below. Right message 下次一起去这里. Left voice message bubble with play icon waveform and 0:12. Right reply bubble containing compact quoted excerpt 晚霞好漂亮 above 我更想和你一起看, with a tiny heart reaction pill attached outside the bubble. Small 已送达 label. One quiet outlined media-transfer row below with thumbnail placeholder, progress indicator, label 等待对方上线 and secondary 视频将在连接后安全传输. Above composer a compact three-pill row 想你了 / 抱抱 / 辛苦啦. Composer 想和你说… with plus and microphone, four-tab bar. RIGHT phone same conversation lightly dimmed under an iOS bottom attachment sheet occupying lower 55 percent, title 分享这一刻, two-by-two large tasteful icon actions 照片 / 拍摄 / 语音 / 小愿望, small informational row 对方离线时，照片和视频会等待传输. Upper conversation visible with sunset image. This is P2P media design, do not show cloud upload or always-available media. No invented technical terms shown to users.

### 2

Use case: ui-mockup. A refined final-product UI design presentation for a private Chinese iPhone couples app 我们, stage two. Landscape canvas showing TWO full front-facing iPhone screens side by side, identical scale, complete top status bars and bottom safe areas, very thin dark phone frames. Warm off-white backdrop. Screens warm ivory #F8F5EF, dark readable Chinese sans-serif text, muted terracotta #B86552 accents and soft sage green. Native implementable iOS 18 controls, generous but useful whitespace, sophisticated quiet intimate design. NO decorative slogans outside phones, NO loud gradients, NO excessive hearts, NO debug controls. Both phones have identical FOUR bottom tabs with thin consistent icons: 对话 / 愿望 / 回忆 / 我们. All screens have realistic readable Chinese text, accessible contrast. Not a social network, no follower counts, no streaks, no public feed. Asset: wishes and shared checklist board. LEFT phone 愿望 selected, large title 小小愿望, plus top right, two-tab segmented control 愿望 / 双人清单 with 愿望 selected. Filter chips 进行中 / 已实现 / 以后再说. Two beautiful concise wish cards: 一起去海边看日落, 来自伴侣, small sunset line illustration, outline action 标记实现; 学会做彼此喜欢的菜, 来自你. Below a subtle fulfilled card with small photo thumbnail, title 周末一起吃早餐, small status 已实现, secondary 已加入回忆. Bottom gentle sage reminder row 愿望提醒, 在你选择的时间里，偶尔想起. RIGHT phone 愿望 selected, same header 小小愿望, segmented control 愿望 / 双人清单 with 双人清单 selected. Compact horizontal category chips 想吃 / 想去 / 想看 / 想做, 想吃 selected. Title 找个周末，一起尝尝. Clean checklist rows with generous touch targets and circular checkboxes: 巷口那家意大利餐厅; 一起做一次早午餐; 新开的日式拉面店. A checked slightly muted row 老城区的冰淇淋 and small trailing photo icon. Bottom add row plus 添加一个想法. Small contextual action on completed item 留作回忆. No progress percentages, no deadlines pressure, no analytics. Maintain consistent typography across phones.

### 3

Use case: ui-mockup. A refined final-product UI design presentation for a private Chinese iPhone couples app 我们, stage two. Landscape canvas showing TWO full front-facing iPhone screens side by side, identical scale, complete top status bars and bottom safe areas, very thin dark phone frames. Warm off-white backdrop. Screens warm ivory #F8F5EF, dark readable Chinese sans-serif text, muted terracotta #B86552 accents and soft sage green. Native implementable iOS 18 controls, generous but useful whitespace, sophisticated quiet intimate design. NO decorative slogans outside phones, NO loud gradients, NO excessive hearts, NO debug controls. Both phones have identical FOUR bottom tabs with thin consistent icons: 对话 / 愿望 / 回忆 / 我们. All screens have realistic readable Chinese text, accessible contrast. Not a social network, no follower counts, no streaks, no public feed. Asset: private memories timeline and detail board. LEFT phone 回忆 selected, large title 我们的回忆, subtitle 一些舍不得忘的小事, plus top right. Compact filter chips 全部 / 照片 / 愿望 / 收藏. Timeline month heading 2026 年 9 月. Large landscape photograph of two cups of coffee and croissants at a sunlit breakfast table, rounded modest corners, caption 不赶时间的早餐, date 9月12日, small tag 愿望实现. Next smaller editorial quote card with quote icon and text 我更想和你一起看, tag 收藏的对话, date 9月10日. Partial next month heading 8 月 with a small coastal photo visible above bottom tabs. No public likes, no comments, no follower activity. RIGHT phone 回忆 selected, memory detail, back chevron title 回忆, ellipsis upper right. Large hero candid breakfast photograph matching left image, title 不赶时间的早餐, date 2026年9月12日. Below short personal caption 今天没有闹钟，也没有着急出门。只有咖啡、阳光和你. Small linked card with wish icon 从一个愿望开始 and subtitle 周末一起吃早餐 and trailing chevron. Quiet bottom action 添加一段记忆 with pencil icon. Do not show automatic system Photos saving. Media exists only on paired devices. Screens should feel like a usable intimate album, not a marketing poster.
