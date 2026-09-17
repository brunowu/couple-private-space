import XCTest
final class PairingOnboardingTests: XCTestCase {
    @MainActor func testCreateInviteShowsQRCodeAndRestoresProgress() throws {
        let app = XCUIApplication(); app.launch()
        guard app.buttons["pair-create"].waitForExistence(timeout: 20) else {
            throw XCTSkip("请在没有既有配对资料的全新模拟器上运行。")
        }
        let endpoint = app.textFields["中继地址"]
        XCTAssertTrue(endpoint.exists)
        endpoint.tap()
        let current = endpoint.value as? String ?? ""
        endpoint.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + "http://127.0.0.1:8794")
        let token = app.secureTextFields["bootstrap-token"]
        token.tap(); token.typeText("local-simulator-only")
        app.buttons["pair-create"].tap()
        XCTAssertTrue(app.images["配对二维码"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["pair-expiry"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "配对邀请"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch()
        XCTAssertTrue(app.images["配对二维码"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["pair-renew"].exists)
    }
    @MainActor func testRestoredInviteAsksForTokenBeforeRenewal() throws {
        let app = XCUIApplication(); app.launch()
        guard app.images["配对二维码"].waitForExistence(timeout: 20) else {
            throw XCTSkip("请先在独立模拟器上创建邀请。")
        }
        XCTAssertTrue(app.secureTextFields["pair-renew-token"].exists)
        app.swipeUp()
        XCTAssertFalse(app.buttons["pair-renew"].isEnabled)
    }
    @MainActor func testImportQRCodeFromPhotos() throws {
        let app = XCUIApplication(); app.launch()
        guard app.segmentedControls.buttons["加入空间"].waitForExistence(timeout: 20) else {
            throw XCTSkip("请在未配对、且已导入二维码截图的独立模拟器上运行。")
        }
        app.segmentedControls.buttons["加入空间"].tap()
        app.buttons["pair-photo-import"].tap()
        // The PhotosPicker is hosted outside the app's accessibility tree. Wait for
        // its initial library load, then select the first thumbnail on this fixture.
        Thread.sleep(forTimeInterval: 8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.42)).tap()
        let payload = app.textViews["pair-input"]
        XCTAssertTrue(payload.waitForExistence(timeout: 15))
        let imported = expectation(for: NSPredicate(format: "value BEGINSWITH %@", "eyJ"), evaluatedWith: payload)
        wait(for: [imported], timeout: 20)
        XCTAssertGreaterThan((payload.value as? String ?? "").count, 1_000)
    }
}

final class ProductFlowTests: XCTestCase {
    @MainActor func testPrivacyControlsAndCancelUnpairing() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap()
        if app.buttons["privacy-shortcut"].waitForExistence(timeout: 5) { app.buttons["privacy-shortcut"].tap() }
        XCTAssertTrue(app.buttons["app-lock-setting"].waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if app.buttons["pair-revoke"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["pair-revoke"].isHittable)
        app.buttons["pair-revoke"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "无法远程抹去伴侣的副本")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["pair-revoke"].exists)
        app.tabBars.buttons["对话"].tap()
        XCTAssertTrue(app.textFields["message-draft"].exists)
    }
    @MainActor func testAnniversaryCreateEditDeleteAndRestart() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap(); app.buttons["添加纪念日"].tap()
        let name = "anniversary-" + String(UUID().uuidString.prefix(6)).lowercased()
        let field = app.textFields["anniversary-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap(); app.staticTexts[name].tap()
        field.tap(); field.typeText("-edited"); app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[name + "-edited"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "纪念日"; shot.lifetime = .keepAlways; add(shot)
        app.staticTexts[name + "-edited"].tap(); app.buttons["删除这个日期"].tap(); app.buttons["删除"].tap()
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts[name + "-edited"])
        wait(for: [removed], timeout: 10)
    }
    @MainActor func testOwnerCyclePrivateNotePersistsAcrossRelaunch() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap()
        XCTAssertTrue(app.buttons["cycle-details"].waitForExistence(timeout: 10))
        let overview = XCTAttachment(screenshot: app.screenshot()); overview.name = "周期概览"; overview.lifetime = .keepAlways; add(overview)
        app.buttons["cycle-details"].tap()
        guard app.buttons["edit-cycle"].waitForExistence(timeout: 5) else { throw XCTSkip("此测试需要周期本人 B 模拟器。") }
        app.buttons["edit-cycle"].tap()
        let note = "private-" + String(UUID().uuidString.prefix(6)).lowercased()
        let field = app.textFields["cycle-private-note"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(note)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch.waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["我们"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap(); app.buttons["cycle-details"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "本人的周期记录"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testCustomWishWindowPersistsAcrossRelaunch() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap(); app.buttons["愿望提醒"].tap()
        let stepper = app.steppers["wish-custom-days"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        // Start from the known preset, then choose a non-preset window.
        app.buttons["wish-window-picker"].tap(); app.buttons["未来 7 天"].tap()
        app.buttons["wish-custom-days-Increment"].tap()
        XCTAssertTrue(app.staticTexts["自定义：未来 8 天"].firstMatch.exists)
        app.buttons["保存提醒设置"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap(); app.buttons["愿望提醒"].tap()
        XCTAssertTrue(app.staticTexts["自定义：未来 8 天"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "自定义愿望窗口"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["wish-window-picker"].tap(); app.buttons["未来 7 天"].tap()
        app.buttons["保存提醒设置"].tap()
    }
    @MainActor func testWishNotificationColdLaunchShowsReceivedWish() throws {
        let app = XCUIApplication(); app.launchArguments = ["--wish-notification-ui-test"]; app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.buttons["Allow"].waitForExistence(timeout: 3) { system.buttons["Allow"].tap() }
        else if system.buttons["允许"].exists { system.buttons["允许"].tap() }
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        if app.staticTexts["missingRecord"].exists { throw XCTSkip("请先运行双模拟器脚本，在 A 上接收测试愿望。") }
        app.terminate()
        let notice = system.staticTexts["你有一个愿望提醒"]
        XCTAssertTrue(notice.waitForExistence(timeout: 25)); notice.tap()
        XCTAssertTrue(app.navigationBars["一个小小愿望"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "周末一起吃早餐 · ")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["进行中"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "愿望通知冷启动跳转"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testGenericMessageNotificationColdLaunchOpensChat() throws {
        let app = XCUIApplication(); app.launchArguments = ["--message-notification-ui-test"]; app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.buttons["Allow"].waitForExistence(timeout: 3) { system.buttons["Allow"].tap() }
        else if system.buttons["允许"].exists { system.buttons["允许"].tap() }
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.terminate()
        let notice = system.staticTexts["你有一条新消息"]
        XCTAssertTrue(notice.waitForExistence(timeout: 25)); notice.tap()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["对话"].exists)
    }
    @MainActor func testQuietHoursSettingsPersistAcrossRelaunch() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap(); app.buttons["愿望提醒"].tap()
        let toggle = app.switches["避开静默时段"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["保存提醒设置"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap(); app.buttons["愿望提醒"].tap()
        XCTAssertEqual(app.switches["避开静默时段"].value as? String, "1")
        XCTAssertTrue(app.staticTexts["静默开始"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "愿望静默时段"; shot.lifetime = .keepAlways; add(shot)
        app.switches["避开静默时段"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["保存提醒设置"].tap()
    }
    @MainActor func testVerifiedAffectionNotificationAction() throws {
        let app = XCUIApplication(); app.launchArguments = ["--affection-notification-ui-test"]; app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.buttons["Allow"].waitForExistence(timeout: 3) { system.buttons["Allow"].tap() }
        else if system.buttons["允许"].exists { system.buttons["允许"].tap() }
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        if app.staticTexts["missingRecord"].exists { throw XCTSkip("需要先运行双模拟器脚本，并在 15 分钟内于接收方 B 验收通知回应。") }
        app.terminate()
        let notice = system.staticTexts["你收到了一份小心意"]
        XCTAssertTrue(notice.waitForExistence(timeout: 25))
        notice.press(forDuration: 1.2)
        let reply = system.buttons["回应这份心意"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5)); reply.tap()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap(); app.swipeUp()
        XCTAssertTrue(app.staticTexts["已回应这份心意。"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "验证后回应小心意"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testCapsuleNotificationColdLaunchOpensOnlyDueContent() throws {
        let app = XCUIApplication(); app.launchArguments = ["--capsule-ui-test"]; app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.buttons["Allow"], chineseAllow = system.buttons["允许"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        else if chineseAllow.exists { chineseAllow.tap() }
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["我们"].tap()
        let privacy = app.buttons["privacy-shortcut"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5)); privacy.tap()
        let scheduled = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "个到期提醒。通知不会")).firstMatch
        for _ in 0..<5 where !scheduled.exists { app.swipeUp() }
        XCTAssertTrue(scheduled.waitForExistence(timeout: 10))
        XCTAssertFalse(scheduled.label.hasPrefix("已安排 0 "))
        app.terminate()
        let notice = system.staticTexts["你有一个时间胶囊提醒"]
        XCTAssertTrue(notice.waitForExistence(timeout: 30))
        notice.tap()
        XCTAssertTrue(app.staticTexts["到时才看得到的心里话"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "到期通知冷启动打开胶囊"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testCapsuleDraftSurvivesTerminationAndSealsAsDuet() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 30))
        app.tabBars.buttons["回忆"].tap(); app.segmentedControls.buttons["时间胶囊"].tap()
        app.buttons["创建时间胶囊"].tap()
        let title = "duet-" + String(UUID().uuidString.prefix(6)).lowercased(), body = "private-draft"
        app.textFields["content-title"].tap(); app.textFields["content-title"].typeText(title)
        let duet = app.switches["两个人各写一份"]
        duet.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.textViews["content-body"].tap(); app.textViews["content-body"].typeText(body)
        XCTAssertTrue(app.staticTexts["草稿已加密保存在本机，尚未发送。"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 20))
        app.tabBars.buttons["回忆"].tap(); app.segmentedControls.buttons["时间胶囊"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.buttons["继续写"].firstMatch.tap()
        XCTAssertEqual(app.textFields["content-title"].value as? String, title)
        XCTAssertEqual(app.textViews["content-body"].value as? String, body)
        XCTAssertEqual(app.switches["两个人各写一份"].value as? String, "1")
        let draft = XCTAttachment(screenshot: app.screenshot()); draft.name = "双人胶囊草稿恢复"; draft.lifetime = .keepAlways; add(draft)
        app.buttons["封存"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[body].exists)
        XCTAssertTrue(app.staticTexts["两个人各写一份 · 到时一起看"].firstMatch.exists)
    }
    @MainActor func testWishReminderPermissionAndScheduling() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 30))
        app.tabBars.buttons["我们"].tap()
        app.buttons["愿望提醒"].tap()
        let toggle = app.switches["接收愿望提醒"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "0" {
            // SwiftUI exposes both the entire row and its nested UISwitch. Tap the control.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["保存提醒设置"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.buttons["Allow"], chineseAllow = system.buttons["允许"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        else if chineseAllow.exists { chineseAllow.tap() }
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已安排 ")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertFalse(status.label.hasPrefix("已安排 0 个"), "The paired fixture must have received wishes to schedule")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "愿望系统提醒"; shot.lifetime = .keepAlways; add(shot)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["保存提醒设置"].tap()
        XCTAssertTrue(app.staticTexts["愿望提醒已关闭。"].waitForExistence(timeout: 10))
    }

    @MainActor func testPairedProductCreatesChecklistMemoryAndLockedCapsule() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 30), "Run on the already paired 我们 · A simulator")
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        app.tabBars.buttons["愿望"].tap()
        app.segmentedControls.buttons["双人清单"].tap()
        app.buttons["添加清单"].tap()
        let list = "breakfast-" + suffix
        app.textViews["content-body"].tap(); app.textViews["content-body"].typeText(list)
        XCTAssertEqual(app.textViews["content-body"].value as? String, list)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[list].waitForExistence(timeout: 10))
        app.buttons["完成：" + list].tap()
        XCTAssertTrue(app.buttons["恢复未完成：" + list].waitForExistence(timeout: 5))
        app.tabBars.buttons["回忆"].tap()
        app.buttons["添加回忆"].tap()
        let memory = "our-day-" + suffix
        app.textFields["content-title"].tap(); app.textFields["content-title"].typeText(memory)
        app.textViews["content-body"].tap(); app.textViews["content-body"].typeText("一起吃了早餐")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[memory].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "共同回忆"; attachment.lifetime = .keepAlways; add(attachment)
        app.segmentedControls.buttons["时间胶囊"].tap()
        app.buttons["创建时间胶囊"].tap()
        let capsule = "tomorrow-" + suffix, secret = "sealed-secret-" + suffix
        app.textFields["content-title"].tap(); app.textFields["content-title"].typeText(capsule)
        app.textViews["content-body"].tap(); app.textViews["content-body"].typeText(secret)
        app.buttons["封存"].tap()
        XCTAssertTrue(app.staticTexts[capsule].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[secret].exists)
        let locked = XCTAttachment(screenshot: app.screenshot()); locked.name = "封存的时间胶囊"; locked.lifetime = .keepAlways; add(locked)
        app.terminate(); app.launch()
        XCTAssertTrue(app.textFields["message-draft"].waitForExistence(timeout: 15))
        app.tabBars.buttons["回忆"].tap()
        app.segmentedControls.buttons["时间胶囊"].tap()
        XCTAssertTrue(app.staticTexts[capsule].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[secret].exists)
    }
}

final class SpaceSmokeTests: XCTestCase {
    @MainActor func testLocalPairChatAndWish() throws {
        let app = XCUIApplication(); app.launchArguments = ["--local-lab"]; app.launch()
        let input = app.textFields["想和你说…"]
        XCTAssertTrue(input.waitForExistence(timeout: 30))
        let message = "hello-" + String(UUID().uuidString.prefix(6))
        input.tap(); input.typeText(message); app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["伴侣 · 周期本人"].tap()
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 10))
        // Move focus away from the multiline chat field before changing tabs. On
        // compact simulators the software keyboard otherwise covers the tab bar.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        app.tabBars.buttons["愿望"].tap()
        let createWish = app.buttons["创建愿望"]
        XCTAssertTrue(createWish.waitForExistence(timeout: 5))
        createWish.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let wish = "weekend-" + String(UUID().uuidString.prefix(6))
        editor.tap(); editor.typeText(wish); app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[wish].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["我"].tap()
        XCTAssertTrue(app.staticTexts[wish].waitForExistence(timeout: 10))
    }
}
