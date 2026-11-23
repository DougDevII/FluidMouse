import XCTest
import SwiftUI
import AppKit
@testable import FluidMouse

/// Offscreen renders of the SwiftUI surfaces, for QA evidence (cell UI-06).
/// Off unless `FLUIDMOUSE_UI_EVIDENCE_DIR` is set. Renders the views only: no
/// service is started (no HID, no event taps) and no preference is written.
/// These images are NOT screenshots of the running app.
@MainActor
final class UIEvidenceRenderTests: XCTestCase {
    func testRenderSurfacesInLightAndDark() throws {
        guard let directory = ProcessInfo.processInfo.environment["FLUIDMOUSE_UI_EVIDENCE_DIR"] else {
            throw XCTSkip("set FLUIDMOUSE_UI_EVIDENCE_DIR to render evidence images")
        }
        let controller = AppController()
        let surfaces: [(name: String, view: AnyView, size: CGSize)] = [
            ("janela-760x560", AnyView(ContentView(controller: controller)), CGSize(width: 760, height: 560)),
            ("ajustes", AnyView(ScrollSettingsView(controller: controller)), CGSize(width: 640, height: 820)),
            ("botoes", AnyView(ButtonSettingsView(controller: controller)), CGSize(width: 640, height: 820)),
            ("mouse-sem-dispositivo", AnyView(RapooHardwareView(controller: controller)), CGSize(width: 640, height: 460)),
            ("teste", AnyView(ScrollTestView(controller: controller)), CGSize(width: 640, height: 620)),
        ]
        let appearances: [(label: String, name: NSAppearance.Name)] = [("claro", .aqua), ("escuro", .darkAqua)]

        for surface in surfaces {
            for appearance in appearances {
                let host = NSHostingView(rootView: surface.view)
                host.frame = NSRect(origin: .zero, size: surface.size)
                host.appearance = NSAppearance(named: appearance.name)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    XCTFail("no bitmap for \(surface.name)")
                    continue
                }
                host.cacheDisplay(in: host.bounds, to: representation)
                let url = URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(surface.name)-\(appearance.label).png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try representation.representation(using: .png, properties: [:])?.write(to: url)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}
