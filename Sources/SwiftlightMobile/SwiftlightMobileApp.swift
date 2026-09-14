import SwiftUI

@main
struct SwiftlightMobileApp: App {
    @StateObject private var model = MobileClientModel()
    @StateObject private var session = MobileStreamingSession()

    var body: some Scene {
        WindowGroup {
            MobileContentView(model: model, session: session)
        }
    }
}
