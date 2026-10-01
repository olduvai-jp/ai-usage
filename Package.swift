// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "UsageCore", targets: ["UsageCore"])],
    targets: [
        .target(name: "UsageCore", path: ".",
                exclude: ["App", "Widget", "Config", "Tests", "build", "MacAIUsage.xcodeproj", "project.yml", "README.md", "THIRD_PARTY_NOTICES.md", "DESIGN.md", "VERIFICATION.md",
                          "Shared/Assets.xcassets", "Shared/UsageViews.swift", "Shared/WidgetView.swift", "Shared/SharedStore.swift", "Shared/RefreshIntent.swift",
                           "Providers/Credentials.swift", "Providers/CodexRPC.swift", "Providers/ProviderClient.swift", "Providers/GrokCLI.swift"],
                 sources: ["Shared/Usage.swift", "Providers/UsageParser.swift", "Providers/GrokSupport.swift", "Providers/GrokBilling.swift"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"], path: "Tests")
    ]
)
