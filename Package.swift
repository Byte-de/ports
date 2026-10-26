// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BytePorts",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "BytePorts", targets: ["PortsApp"]),
        .executable(name: "ports-diagnostics", targets: ["PortsDiagnostics"]),
        .executable(name: "ports-tunnel-runner", targets: ["TunnelRunner"]),
        .library(name: "PortsCore", targets: ["PortsCore"]),
    ],
    targets: [
        .target(name: "ProcessBridge", publicHeadersPath: "include"),
        .executableTarget(name: "TunnelRunner"),
        .target(name: "PortsCore", dependencies: ["ProcessBridge"]),
        .executableTarget(name: "PortsApp", dependencies: ["PortsCore"]),
        .executableTarget(name: "PortsDiagnostics", dependencies: ["PortsCore"]),
        .testTarget(name: "PortsCoreTests", dependencies: ["PortsCore"]),
    ]
)
