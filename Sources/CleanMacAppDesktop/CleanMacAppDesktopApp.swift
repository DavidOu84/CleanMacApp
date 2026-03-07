import SwiftUI

@main
struct CleanMacAppDesktopApp: App {
    private let viewModel: AppViewModel?
    private let startupError: String?

    init() {
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
