// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokiwatari",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TokiwatariTracking", targets: ["TokiwatariTracking"]),
        .library(name: "Tokiwatari", targets: ["Tokiwatari"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "TokiwatariTracking"),
        .target(
            name: "Tokiwatari",
            dependencies: [
                "TokiwatariTracking",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TokiwatariTests",
            dependencies: [
                "Tokiwatari",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
