import SwiftUI
import UI
import Application
#if DEBUG
import DevelopmentSupport

@main struct CouplePrivateSpaceApp: App {
    @UIApplicationDelegateAdaptor(SpaceNotificationDelegate.self) private var notificationDelegate
    @StateObject private var lab = LocalPairLab()
    var body: some Scene {
        WindowGroup {
            if !ProcessInfo.processInfo.arguments.contains("--local-lab") {
                NetworkSpaceView()
            } else {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("本机双端演练 · 不连接真实伴侣").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Picker("视角", selection: Binding(get: { lab.side }, set: { side in Task { await lab.selectSide(side) } })) {
                            Text("我").tag(0); Text("伴侣 · 周期本人").tag(1)
                        }.pickerStyle(.segmented)
                        Button { lab.online.toggle(); Task { await lab.synchronize() } } label: {
                            Image(systemName: lab.online ? "network" : "wifi.slash")
                        }.accessibilityLabel(lab.online ? "模拟离线" : "恢复连接")
                    }
                }.padding(.horizontal, 18).padding(.vertical, 8).background(.thinMaterial)
                if lab.ready {
                    SpaceView(state: lab.state, localID: lab.localID, isCycleOwner: lab.side == 1,
                              send: lab.sendText, addWish: lab.createWish,
                              changeWish: { wish, status in await lab.changeWish(wish, to: status) }, cycle: lab.updateCycle)
                } else { Spacer(); ProgressView("正在打开本地空间"); Spacer() }
                if let error = lab.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
            }.task { await lab.start() }
            }
        }
    }
}
#else
@main struct CouplePrivateSpaceApp: App {
    @UIApplicationDelegateAdaptor(SpaceNotificationDelegate.self) private var notificationDelegate
    var body: some Scene { WindowGroup { NetworkSpaceView() } }
}
#endif
