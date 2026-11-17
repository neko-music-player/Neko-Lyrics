import SwiftUI

@main
struct NekoLyricsPhoneApp: App {
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        WindowGroup {
            ViewerView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
