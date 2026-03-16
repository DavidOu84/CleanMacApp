import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct CleanMacAppDesktopApp: App {
    private let viewModel: AppViewModel?
    private let startupError: String?

    init() {
#if os(macOS)
        // Ensure the app behaves as a standard foreground app (Dock + Cmd+Tab).
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
#endif
        do {
            let env = try AppEnvironment.live()
            viewModel = AppViewModel(env: env)
            startupError = nil
        } catch {
            viewModel = nil
            startupError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup("CleanMacApp") {
            if let viewModel {
                ContentView(viewModel: viewModel)
            } else {
                VStack(spacing: 12) {
                    Text("Failed to start CleanMacApp")
                        .font(.headline)
                    Text(startupError ?? "Unknown startup error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(minWidth: 640, minHeight: 400)
            }
        }
    }
}
