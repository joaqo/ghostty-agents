import Testing
import AppKit
@testable import Ghostty

@Suite
struct TerminalRestorableTests {
    @MainActor
    @Test(arguments: [false, true])
    func commandWindowRestoresWorkingDirectory(shellReportedDirectory: Bool) throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        config.workingDirectory = NSTemporaryDirectory()
        let controller = TerminalController(app, withBaseConfig: config)
        defer {
            controller.focusedSurfaceDidChange(to: nil)
            controller.surfaceTree = .init()
            controller.close()
        }
        let window = try #require(controller.window)
        #expect(window.isRestorable)
        let surface = try #require(controller.surfaceTree.first)
        if shellReportedDirectory { surface.pwd = NSHomeDirectory() }

        let data = try JSONEncoder().encode(TerminalRestorableState(from: controller))
        let restored = try JSONDecoder().decode(TerminalRestorableState.self, from: data)
        let restoredSurface = try #require(restored.surfaceTree.first)
        #expect(restoredSurface.pwd == (shellReportedDirectory ? NSHomeDirectory() : config.workingDirectory))
    }
}
