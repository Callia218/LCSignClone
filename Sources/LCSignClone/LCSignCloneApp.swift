import SwiftUI

@main
struct LCSignCloneApp: App {

    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .onOpenURL { url in
                    Task { await model.acceptIncoming(url) }
                }
        }
    }
}
