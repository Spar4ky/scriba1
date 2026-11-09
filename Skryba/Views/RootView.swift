import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        LibraryView()
            .fullScreenCover(isPresented: $app.isRecorderPresented) {
                RecordingView()
            }
            .sheet(isPresented: $app.isSettingsPresented) {
                SettingsView()
            }
            .fileImporter(
                isPresented: $app.isImporterPresented,
                allowedContentTypes: [.audio, .movie],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await app.importFiles(urls, source: .imported) }
                case .failure(let error):
                    app.presentError(error.localizedDescription)
                }
            }
            .overlay(alignment: .top) {
                ToastOverlay(toast: app.toast)
            }
            .overlay {
                if app.isImporting {
                    ImportingOverlay(message: app.busyMessage)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: app.isImporting)
            .alert(
                app.alert?.title ?? "",
                isPresented: $app.isAlertPresented,
                presenting: app.alert
            ) { alert in
                if alert.offersSettings {
                    Button("Otwórz Ustawienia") { app.openSystemSettings() }
                }
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
            .onChange(of: scenePhase) { _, phase in
                app.scenePhaseChanged(phase)
            }
    }
}
