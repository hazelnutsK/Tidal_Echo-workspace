import SwiftUI

@main
struct TidalEchoApp: App {
    @UIApplicationDelegateAdaptor(NativeAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--imessage-ui-review") {
            return IMessageReviewFixture.makeModel()
        }
        if ProcessInfo.processInfo.arguments.contains("--space-ui-review") {
            return SpaceReviewFixture.makeModel()
        }
        #endif
        return AppModel()
    }()

    var body: some Scene {
        WindowGroup {
            content
                .preferredColorScheme(model.theme.preferredColorScheme)
        }
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--imessage-ui-review") {
            // No bootstrap, relay connection, or real messages in UI tests.
            ChatView(model: model)
        } else if ProcessInfo.processInfo.arguments.contains("--space-ui-review") {
            // 空间页截图：样例数据，不连 relay。
            SpaceReviewScreen(model: model, page: SpaceReviewFixture.page)
        } else {
            RootView(model: model)
        }
        #else
        RootView(model: model)
        #endif
    }
}

