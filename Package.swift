// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FluidMouse",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FluidMouse", targets: ["FluidMouse"])],
    targets: [
        .target(name: "FluidMouseCore"),
        .target(name: "FluidMouseEvents", dependencies: ["FluidMouseCore"]),
        .executableTarget(name: "FluidMouse", dependencies: ["FluidMouseCore", "FluidMouseEvents"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                             .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement"),
                             .linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]),
        .testTarget(name: "FluidMouseCoreTests", dependencies: ["FluidMouseCore"]),
        .testTarget(name: "FluidMouseEventsTests", dependencies: ["FluidMouseEvents"])
    ]
)
