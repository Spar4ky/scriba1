import SwiftUI

@main
struct SkrybaApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Brand.indigo)
                .fontDesign(.rounded)
                .onOpenURL { url in
                    app.handleOpenURL(url)
                }
        }
    }
}
