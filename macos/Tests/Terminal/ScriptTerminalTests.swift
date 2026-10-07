import Testing
import AppKit
@testable import Ghostty

@Suite
struct ScriptTerminalTests {
    @MainActor
    @Test
    func processSeesItsTerminalIDOnScreen() async throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/usr/bin/printenv GHOSTTY_AGENTS_TERMINAL_ID"
        config.waitAfterCommand = true
        let controller = TerminalController(app, withBaseConfig: config)
        defer {
            controller.focusedSurfaceDidChange(to: nil)
            controller.surfaceTree = .init()
            controller.close()
        }
        let surface = try #require(controller.surfaceTree.first)
        let terminal = ScriptTerminal(surfaceView: surface)

        let deadline = ContinuousClock.now + .seconds(10)
        while !terminal.screenText.contains(surface.id.uuidString), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(terminal.screenText.contains(surface.id.uuidString))
    }
}
