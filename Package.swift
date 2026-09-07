// swift-tools-version: 6.2
import PackageDescription

let commandLineToolsTestingLibraryPath =
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let testingLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", commandLineToolsTestingLibraryPath,
        "-Xlinker", "-rpath",
        "-Xlinker", commandLineToolsTestingLibraryPath
    ], .when(platforms: [.macOS]))
]

let package = Package(
    name: "PersonalCalendar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CalendarDomain", targets: ["CalendarDomain"]),
        .library(name: "WorkspaceDomain", targets: ["WorkspaceDomain"]),
        .library(name: "CalendarPersistence", targets: ["CalendarPersistence"]),
        .executable(name: "PersonalCalendar", targets: ["CalendarApp"]),
        .executable(name: "jelly-mcp", targets: ["JellyMCPBridge"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "70eff261d7f462cad1fff51e05bcc74aa0b0f420"
        ),
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.0.0"
        )
    ],
    targets: [
        .target(name: "CalendarDomain"),
        .target(
            name: "WorkspaceDomain",
            dependencies: ["CalendarDomain"]
        ),
        .target(
            name: "CalendarPersistence",
            dependencies: ["CalendarDomain", "WorkspaceDomain"]
        ),
        .target(
            name: "JellyMCP",
            dependencies: ["CalendarDomain", "WorkspaceDomain"]
        ),
        .executableTarget(
            name: "JellyMCPBridge"
        ),
        .executableTarget(
            name: "CalendarApp",
            dependencies: [
                "CalendarDomain",
                "WorkspaceDomain",
                "CalendarPersistence",
                "JellyMCP",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit")
            ]
        ),
        .testTarget(
            name: "CalendarDomainTests",
            dependencies: [
                "CalendarDomain",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: testingLinkerSettings
        ),
        .testTarget(
            name: "WorkspaceDomainTests",
            dependencies: [
                "CalendarDomain",
                "WorkspaceDomain",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "CalendarPersistenceTests",
            dependencies: [
                "CalendarDomain",
                "WorkspaceDomain",
                "CalendarPersistence",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "JellyMCPTests",
            dependencies: [
                "JellyMCP",
                "CalendarDomain",
                "WorkspaceDomain",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "CalendarAppTests",
            dependencies: [
                "CalendarApp",
                "CalendarDomain",
                "WorkspaceDomain",
                "CalendarPersistence",
                "JellyMCP",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
