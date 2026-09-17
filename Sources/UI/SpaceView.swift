import SwiftUI
import Domain

#if os(iOS)
public struct SpaceView: View {
    let state: SharedState
    let localID: UUID
    let isCycleOwner: Bool
    let send: (String) async -> Void
    let addWish: (String) async -> Void
    let changeWish: (Wish, WishStatus) async -> Void
    let cycle: (Date, Bool) async -> Void
    let developmentDescription: String
    @State private var tab = 0
    @State private var draft = ""
    @State private var wishDraft = ""
    @State private var composingWish = false
    @State private var cycleDate = Date()
    @FocusState private var chatFocused: Bool
    private let rose = Color(red: 0.56, green: 0.29, blue: 0.36)
    private let paper = Color(red: 0.98, green: 0.96, blue: 0.94)
    public init(state: SharedState, localID: UUID, isCycleOwner: Bool,
                send: @escaping (String) async -> Void, addWish: @escaping (String) async -> Void,
                changeWish: @escaping (Wish, WishStatus) async -> Void, cycle: @escaping (Date, Bool) async -> Void,
                developmentDescription: String = "当前是本机双端演练，尚未连接真实伴侣；远程配对、APNs 与系统提醒接线仍在开发。") {
        self.state = state; self.localID = localID; self.isCycleOwner = isCycleOwner
        self.send = send; self.addWish = addWish; self.changeWish = changeWish; self.cycle = cycle
        self.developmentDescription = developmentDescription
    }
    public var body: some View {
        TabView(selection: $tab) {
            NavigationStack { chat.navigationTitle("对话").navigationBarTitleDisplayMode(.large) }
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }.tag(0)
            NavigationStack { wishes.navigationTitle("小小愿望").toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { composingWish = true } label: { Image(systemName: "plus") }.accessibilityLabel("创建愿望") }
            } }.tabItem { Label("愿望", systemImage: "sparkles") }.tag(1)
            NavigationStack { together.navigationTitle("我们") }
                .tabItem { Label("我们", systemImage: "heart") }.tag(2)
        }.tint(rose)
        .sheet(isPresented: $composingWish) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 20) {
                    Text("有件小事，想和你一起。") .font(.title2.weight(.medium))
                    TextEditor(text: $wishDraft).frame(minHeight: 140).padding(10).background(paper).clipShape(RoundedRectangle(cornerRadius: 16))
                    Text("送达后立即可见。提醒时间由对方的手机决定。") .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }.padding(24).navigationTitle("写一个愿望").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { composingWish = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { let text = wishDraft; Task { await addWish(text); wishDraft = ""; composingWish = false } }.disabled(wishDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    }
            }.tint(rose)
        }
    }
    private var chat: some View {
        VStack(spacing: 0) {
            if state.messages.isEmpty {
                Spacer()
                Image(systemName: "heart.text.clipboard").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(rose).padding()
                Text("日常的小事，都可以放在这里。") .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(state.messages.values.sorted { $0.version < $1.version }, id: \.id) { message in
                            HStack {
                                if message.author == localID { Spacer(minLength: 45) }
                                Text(message.text).textSelection(.enabled).padding(14)
                                    .background(message.author == localID ? rose.opacity(0.12) : Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                                if message.author != localID { Spacer(minLength: 45) }
                            }
                        }
                    }.padding(20)
                }.defaultScrollAnchor(.bottom)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("想和你说…", text: $draft, axis: .vertical)
                    .focused($chatFocused).lineLimit(1...5).padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 20))
                Button { let text = draft; draft = ""; chatFocused = false; Task { await send(text) } } label: {
                    Image(systemName: "arrow.up").font(.headline).foregroundStyle(.white).padding(13).background(rose).clipShape(Circle())
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送")
            }.padding(16)
        }.background(paper)
    }
    private var wishes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("不着急，一件一件实现。") .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                if state.wishes.isEmpty {
                    ContentUnavailableView("给未来留一个小愿望", systemImage: "sparkles", description: Text("一起吃饭、散步，或去一个想去的地方。"))
                    Button("写下第一个愿望") { composingWish = true }.buttonStyle(.bordered)
                }
                ForEach(state.wishes.values.sorted { $0.id.uuidString < $1.id.uuidString }, id: \.id) { wish in
                    VStack(alignment: .leading, spacing: 16) {
                        Label(statusTitle(wish.status), systemImage: wish.status == .fulfilled ? "checkmark.seal" : "sparkle").font(.caption).foregroundStyle(rose)
                        Text(wish.text).font(.title3).fixedSize(horizontal: false, vertical: true)
                        Menu("轻轻记下进展") {
                            ForEach([WishStatus.active, .fulfilled, .deferred, .archived], id: \.self) { status in
                                Button(statusTitle(status)) { Task { await changeWish(wish, status) } }
                            }
                        }.font(.footnote)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(22).background(.white).clipShape(RoundedRectangle(cornerRadius: 22))
                }
            }.padding(22)
        }.background(paper)
    }
    private var together: some View {
        List {
            Section {
                Label("只属于两个人", systemImage: "heart").font(.headline)
                Text("没有公开账号，也没有热闹的动态。") .foregroundStyle(.secondary)
            }
            Section("周期 · 由本人决定分享") {
                if let projection = state.cycle, !projection.revoked, let start = projection.startDate {
                    LabeledContent("最近开始日期", value: start)
                    Text("这里只显示已共享的日期，不提供医疗预测。") .font(.footnote).foregroundStyle(.secondary)
                } else { Text("尚未分享周期日期").foregroundStyle(.secondary) }
                if isCycleOwner {
                    DatePicker("开始日期", selection: $cycleDate, displayedComponents: .date)
                    Button("分享此日期") { Task { await cycle(cycleDate, true) } }
                    Button("停止共享", role: .destructive) { Task { await cycle(cycleDate, false) } }
                } else { Text("伴侣视角只读").font(.caption).foregroundStyle(.secondary) }
            }
            Section("当前开发版本") {
                Label("本地数据库已加密", systemImage: "lock.doc")
                Label("消息使用 libsignal 加密", systemImage: "lock.shield")
                Text(developmentDescription).font(.footnote).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(paper)
    }
    private func statusTitle(_ status: WishStatus) -> String {
        switch status { case .active: "进行中"; case .fulfilled: "已实现"; case .deferred: "以后再说"; case .archived: "已归档" }
    }
}

#endif
