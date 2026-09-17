#if os(iOS)
import SwiftUI
import Domain

struct CycleOverviewCard: View {
    let entry: CycleEntry?
    let projection: SharedCycleProjection?
    let isOwner: Bool

    private var start: String? { isOwner ? entry?.record.startDate : (projection?.revoked == false ? projection?.startDate : nil) }
    private var length: Int? {
        if isOwner { return entry?.usualLength }
        guard let start, let next = projection?.estimatedNextDate, projection?.revoked == false else { return nil }
        return CivilDate.distance(from: start, to: next)
    }
    private var recordedEnd: Int? {
        guard let start, let end = isOwner ? entry?.record.endDate : projection?.endDate,
              let distance = CivilDate.distance(from: start, to: end) else { return nil }
        return distance + 1
    }
    private var currentDay: Int? {
        guard let start, let length,
              let distance = CivilDate.distance(from: start, to: CivilDate.string(Date())),
              (0..<length).contains(distance) else { return nil }
        return distance + 1
    }
    private var ovulationDay: Int? {
        guard isOwner, let length, (21...35).contains(length) else { return nil }
        return length - 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(isOwner ? "我的周期" : "伴侣的周期").font(.title3.weight(.semibold))
                Spacer()
                Label(isOwner ? "由我决定分享" : "仅显示已分享", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let start, let length, (1...180).contains(length) {
                Text(currentDay.map { "本周期 · 第 \($0) 天 / 共 \(length) 天" } ?? "最近记录 · 周期 \(length) 天")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    dayRow(startDay: 1, count: min(length, 18), start: start)
                    if length > 18 { dayRow(startDay: 19, count: min(length - 18, 18), start: start) }
                }
                if length > 36 { Text("仅显示前 36 天，其余 \(length - 36) 天可在周期详情查看。")
                    .font(.caption).foregroundStyle(.secondary) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        key(color: SpaceStyle.sage, title: "已过去", filled: true)
                        key(color: SpaceStyle.accent, title: "经期记录", filled: true)
                        if ovulationDay != nil {
                            key(color: .orange, title: "易孕期估算", filled: false)
                            key(color: SpaceStyle.accent, title: "预计排卵", filled: false)
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), alignment: .leading, spacing: 6) {
                        key(color: SpaceStyle.sage, title: "已过去", filled: true)
                        key(color: SpaceStyle.accent, title: "经期记录", filled: true)
                        if ovulationDay != nil {
                            key(color: .orange, title: "易孕期估算", filled: false)
                            key(color: SpaceStyle.accent, title: "预计排卵", filled: false)
                        }
                    }
                }.font(.caption2)
                Text("仅按记录与周期长度粗略估算，不能用于避孕或医疗判断。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(isOwner ? "记录开始日期和周期长度后，就能在这里看到周期圆点。" : "伴侣尚未同时分享开始日期和下次日期估算。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func dayRow(startDay: Int, count: Int, start: String) -> some View {
        let leadingSlots = (18 - count) / 2
        return HStack(spacing: 0) {
            ForEach(0..<18, id: \.self) { slot in
                Group {
                    if slot >= leadingSlots && slot < leadingSlots + count {
                        dayDot(startDay + slot - leadingSlots, start: start)
                    } else {
                        Color.clear.frame(width: 10, height: 10).accessibilityHidden(true)
                    }
                }.frame(maxWidth: .infinity)
            }
        }.frame(maxWidth: .infinity)
    }

    private func dayDot(_ day: Int, start: String) -> some View {
        let today = CivilDate.string(Date())
        let date = CivilDate.adding(days: day - 1, to: start) ?? start
        let past = date <= today
        let ongoing = isOwner ? entry?.record.endDate == nil : projection?.stage == "尚未记录结束"
        let recorded = day <= (recordedEnd ?? (ongoing ? currentDay ?? 1 : 1))
        let ovulation = ovulationDay == day
        let fertile = ovulationDay.map { (max(1, $0 - 5)...min(length ?? 1, $0 + 1)).contains(day) } ?? false
        let fill = past ? (recorded ? SpaceStyle.accent : SpaceStyle.sage) : Color.clear
        let outline = ovulation ? SpaceStyle.accent : (fertile ? Color.orange : SpaceStyle.border)
        return Circle().fill(fill).frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(outline, lineWidth: 1))
            .overlay {
                if ovulation { Circle().strokeBorder(SpaceStyle.accent.opacity(0.55), lineWidth: 1).frame(width: 13, height: 13) }
            }
            .frame(width: 10, height: 10)
            .accessibilityLabel("第 \(day) 天，\(recorded && past ? "经期记录" : past ? "已过去" : ovulation ? "预计排卵" : fertile ? "易孕期估算" : "尚未到来")")
    }

    private func key(color: Color, title: String, filled: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(filled ? color : .clear).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(color, lineWidth: 1))
            Text(title).foregroundStyle(.secondary)
        }
    }
}

struct CycleDetailView: View {
    let entry: CycleEntry?
    let projection: SharedCycleProjection?
    let isOwner: Bool
    let save: (CycleEntry) async throws -> Void
    @State private var editing = false
    var body: some View {
        List {
            Section {
                Label(isOwner ? "照顾自己的节奏" : "了解伴侣的节奏", systemImage: "leaf").font(.title2)
                Text(isOwner ? "记录属于你，分享也由你决定。" : "这里只显示伴侣选择分享的信息。").foregroundStyle(.secondary)
            }
            if isOwner, let entry {
                Section("我的记录 · 仅本机") {
                    LabeledContent("开始日期", value: entry.record.startDate)
                    if let end = entry.record.endDate { LabeledContent("结束日期", value: end) }
                    LabeledContent("通常周期", value: "\(entry.usualLength) 天")
                    if let days = CivilDate.distance(from: entry.record.startDate, to: CivilDate.string(Date())), days >= 0 {
                        LabeledContent("距本次开始", value: "第 \(days + 1) 天")
                    }
                    if let next = entry.estimatedNextDate {
                        LabeledContent(next < CivilDate.string(Date()) ? "上次估算 · 已过期" : "下次日期估算", value: next)
                    }
                    if let note = entry.record.note, !note.isEmpty { Text(note) }
                }
            } else if isOwner {
                Section { Text("还没有本机记录。填写实际日期后才会显示估算。").foregroundStyle(.secondary) }
            }
            Section(isOwner ? "伴侣可见" : "伴侣共享的记录") {
                if let projection, !projection.revoked {
                    if let start = projection.startDate { LabeledContent("开始日期", value: start) }
                    if let end = projection.endDate { LabeledContent("结束日期", value: end) }
                    if let next = projection.estimatedNextDate {
                        LabeledContent(next < CivilDate.string(Date()) ? "上次估算 · 已过期" : "下次日期估算", value: next)
                    }
                    if let stage = projection.stage { Text(stage) }
                } else { Text("目前没有共享周期信息").foregroundStyle(.secondary) }
            }
            if isOwner {
                Section { Button(entry == nil ? "记录我的周期" : "编辑记录与共享") { editing = true }.accessibilityIdentifier("edit-cycle") }
            }
            Section {
                Text("估算仅按你填写的开始日期和通常周期长度计算，不自动推算多轮周期。它不是医疗结论，不用于避孕或生育决策。")
                Text("私人备注只在本人设备加密保存。停止共享会通知伴侣端隐藏信息，无法收回对方已截图或自行保留的内容。")
            }.font(.footnote).foregroundStyle(.secondary)
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(SpaceStyle.paper)
            .navigationTitle("周期").sheet(isPresented: $editing) {
            CycleEditor(entry: entry, projection: projection, save: save)
        }
    }
}

private struct CycleEditor: View {
    let save: (CycleEntry) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var hasEnd: Bool
    @State private var length: Int
    @State private var note: String
    @State private var dates: Bool
    @State private var estimate: Bool
    @State private var stage: Bool
    @State private var saving = false
    @State private var failure: String?
    init(entry: CycleEntry?, projection: SharedCycleProjection?, save: @escaping (CycleEntry) async throws -> Void) {
        self.save = save
        let start = (entry?.record.startDate ?? projection?.startDate).flatMap(CivilDate.localDate) ?? Date()
        _start = State(initialValue: start)
        _end = State(initialValue: (entry?.record.endDate ?? projection?.endDate).flatMap(CivilDate.localDate) ?? max(start, Date()))
        _hasEnd = State(initialValue: entry?.record.endDate != nil || projection?.endDate != nil)
        _length = State(initialValue: entry?.usualLength ?? 28); _note = State(initialValue: entry?.record.note ?? "")
        _dates = State(initialValue: entry?.shareDates ?? (projection?.startDate != nil && projection?.revoked == false))
        _estimate = State(initialValue: entry?.shareEstimate ?? (projection?.estimatedNextDate != nil && projection?.revoked == false))
        _stage = State(initialValue: entry?.shareStage ?? (projection?.stage != nil && projection?.revoked == false))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("实际记录") {
                    DatePicker("开始日期", selection: $start, in: ...Date(), displayedComponents: .date)
                    Toggle("已结束", isOn: $hasEnd)
                    if hasEnd { DatePicker("结束日期", selection: $end, in: start...max(start, Date()), displayedComponents: .date) }
                    Stepper("通常周期：\(length) 天", value: $length, in: 1...180)
                    Text("请按自己的记录调整长度；28 天只是输入初值。").font(.footnote).foregroundStyle(.secondary)
                    TextField("私人备注，仅自己可见", text: $note, axis: .vertical).accessibilityIdentifier("cycle-private-note")
                }
                Section("选择分享给伴侣的内容") {
                    Toggle("分享开始与结束日期", isOn: $dates)
                    Toggle("分享下次日期估算", isOn: $estimate)
                    Toggle("分享记录阶段", isOn: $stage)
                    Button("关闭所有共享", role: .destructive) { dates = false; estimate = false; stage = false }
                    Text("保存后生效。日期估算也可能透露你的周期时间，请按自己的意愿选择。").font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }.scrollContentBackground(.hidden).background(SpaceStyle.paper)
                .navigationTitle("我的周期").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saving = true
                        Task {
                            do {
                                let entry = CycleEntry(record: PrivateCycleRecord(startDate: CivilDate.string(start), endDate: hasEnd ? CivilDate.string(end) : nil, note: note), usualLength: length, shareDates: dates, shareEstimate: estimate, shareStage: stage)
                                try await save(entry); dismiss()
                            } catch { failure = "未能保存，请检查日期并重试。" }
                            saving = false
                        }
                    }.disabled(saving || (hasEnd && CivilDate.string(end) < CivilDate.string(start)))
                }
            }.interactiveDismissDisabled(saving)
        }
    }
}

struct AnniversaryOverviewCard: View {
    let records: [UUID: JournalRecord<AnniversaryContent>]
    @Binding var editing: AnniversaryDraft?
    let activeWishCount: Int
    let showWishes: () -> Void

    private var today: String { CivilDate.string(Date()) }
    private var relationship: JournalRecord<AnniversaryContent>? {
        records[AnniversaryContent.relationshipID].flatMap { $0.value.deleted ? nil : $0 }
    }
    private var anniversaries: [JournalRecord<AnniversaryContent>] {
        records.values.filter { !$0.value.deleted && $0.id != AnniversaryContent.relationshipID }.sorted {
            let first = $0.value.nextOccurrence(today: today) ?? "9999"
            let second = $1.value.nextOccurrence(today: today) ?? "9999"
            return first == second ? $0.id.uuidString < $1.id.uuidString : first < second
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 14) {
                Image(systemName: "calendar").font(.title3).foregroundStyle(SpaceStyle.accent)
                    .frame(width: 44, height: 44).background(SpaceStyle.accent.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("属于我们的日子").font(.headline)
                    Text("重要的日子，就放在这里").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let relationship {
                Button { editing = AnniversaryDraft(id: relationship.id, value: relationship.value) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "heart.fill").foregroundStyle(SpaceStyle.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("一起走过的日子").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text("从 \(relationship.value.date) 开始").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let days = CivilDate.distance(from: relationship.value.date, to: today), days >= 0 {
                            Text("\(days) 天").font(.headline).foregroundStyle(SpaceStyle.accent)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(SpaceStyle.softSurface, in: RoundedRectangle(cornerRadius: 14))
                }.accessibilityIdentifier("relationship-card")
            } else {
                Button("记录关系开始日", systemImage: "heart") {
                    editing = AnniversaryDraft(id: AnniversaryContent.relationshipID, value: AnniversaryContent(title: "关系开始日", date: CivilDate.string(Date())))
                }.font(.subheadline).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(SpaceStyle.softSurface, in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(anniversaries) { record in
                Button { editing = AnniversaryDraft(id: record.id, value: record.value) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "heart").foregroundStyle(SpaceStyle.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.value.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            if let next = record.value.nextOccurrence(today: today), let days = CivilDate.distance(from: today, to: next) {
                                Text(days == 0 ? "就是今天" : "还有 \(days) 天 · \(next)").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("已走过 · \(record.value.date)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(SpaceStyle.softSurface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            HStack(spacing: 10) {
                Button("添加纪念日", systemImage: "plus") {
                    editing = AnniversaryDraft(id: UUID(), value: AnniversaryContent(title: "", date: today))
                }
                Button { showWishes() } label: {
                    Label(activeWishCount == 0 ? "愿望清单" : "愿望 · \(activeWishCount)", systemImage: "gift")
                }
            }.font(.subheadline).buttonStyle(.plain).tint(SpaceStyle.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
    }
}

struct AnniversaryDraft: Identifiable { let id: UUID; var value: AnniversaryContent }
struct AnniversaryEditor: View, Equatable {
    let draft: AnniversaryDraft
    let exists: Bool
    let save: (EventPayload, UUID) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var date: Date
    @State private var yearly: Bool
    @State private var saving = false
    @State private var deleting = false
    @State private var failure: String?
    private var relationship: Bool { draft.id == AnniversaryContent.relationshipID }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.draft.id == rhs.draft.id && lhs.draft.value == rhs.draft.value && lhs.exists == rhs.exists
    }
    init(draft: AnniversaryDraft, exists: Bool, save: @escaping (EventPayload, UUID) async throws -> Void) {
        self.draft = draft; self.exists = exists; self.save = save
        _title = State(initialValue: draft.value.title); _date = State(initialValue: CivilDate.localDate(draft.value.date) ?? Date())
        _yearly = State(initialValue: draft.value.repeatsYearly)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !relationship { TextField("纪念日名称", text: $title).accessibilityIdentifier("anniversary-title") }
                    if relationship { DatePicker("开始日期", selection: $date, in: ...Date(), displayedComponents: .date) }
                    else { DatePicker("日期", selection: $date, displayedComponents: .date); Toggle("每年纪念", isOn: $yearly) }
                    Text("双方都可以编辑，保存后加密同步。2 月 29 日在非闰年按 2 月 28 日纪念。").font(.footnote).foregroundStyle(.secondary)
                }
                if exists { Section { Button("删除这个日期", role: .destructive) { deleting = true }.disabled(saving) } }
                if let failure { Text(failure).foregroundStyle(.red) }
            }.scrollContentBackground(.hidden).background(SpaceStyle.paper)
                .navigationTitle(relationship ? "关系开始日" : "纪念日").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { commit(deleted: false) }.disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.confirmationDialog("删除后会同步到伴侣设备", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除", role: .destructive) { commit(deleted: true) }
            }.interactiveDismissDisabled(saving)
        }
    }
    private func commit(deleted: Bool) {
        saving = true
        Task {
            do {
                try await save(.journal(.anniversary(AnniversaryContent(title: title, date: CivilDate.string(date), repeatsYearly: relationship || yearly, deleted: deleted))), draft.id)
                dismiss()
            } catch { failure = "未能保存，请稍后重试。" }
            saving = false
        }
    }
}
#endif
