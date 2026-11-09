import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Układ główny: na iPadzie lista nagrań obok szczegółów (dwie kolumny),
/// na iPhonie i w wąskim oknie – lista, z której otwiera się nagranie.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            if let id = app.selectedID {
                RecordingDetailView(recordingID: id)
                    .id(id)
            } else {
                DetailPlaceholder()
            }
        }
        .navigationSplitViewStyle(.balanced)
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

/// Prawa kolumna na iPadzie, gdy żadne nagranie nie jest wybrane.
struct DetailPlaceholder: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Brand.gradient)
                    .opacity(0.14)
                    .frame(width: 120, height: 120)
                Image(systemName: "text.quote")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Brand.gradient)
            }
            VStack(spacing: 8) {
                Text(app.store.recordings.isEmpty ? "Tu pojawi się transkrypcja" : "Wybierz nagranie z listy")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Nagraj wykład albo udostępnij nagranie z Dyktafonu – tekst zrobi się sam i skopiujesz go jednym dotknięciem.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            Button {
                Task { await app.beginRecording() }
            } label: {
                Label("Nagraj", systemImage: "mic.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Brand.recordGradient, in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
