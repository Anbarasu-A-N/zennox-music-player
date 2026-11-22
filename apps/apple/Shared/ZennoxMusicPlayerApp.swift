import SwiftUI
import ZennoxUI

@main
struct ZennoxMusicPlayerApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    init() {
        do {
            _model = State(initialValue: try AppModel())
        } catch {
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    RootView(model: model)
                } else {
                    ContentUnavailableView("Zennox couldn’t open its library", systemImage: "exclamationmark.triangle",
                                           description: Text(startupError ?? "Unknown error"))
                }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 480)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1040, height: 700)
        #endif
    }
}
