import ProjectDescription

let bundleIdPrefix = "dev.mtmcapital.hermes"
let deploymentTargets: DeploymentTargets = .multiplatform(iOS: "27.0", macOS: "27.0")

/// Apple Developer team used for automatic code signing.
let developmentTeam = "S4J5D3N22R"

let project = Project(
    name: "Hermes",
    options: .options(
        automaticSchemesOptions: .disabled,
        disableBundleAccessors: true,
        disableSynthesizedResourceAccessors: true
    ),
    packages: [
        .local(path: "HermesKit")
    ],
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
            "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            // Build number (CFBundleVersion). CI previews override it with a
            // unique value per run, see .github/workflows/preview.yml.
            "CURRENT_PROJECT_VERSION": "1",
            // macOS: sandboxed app that only needs outgoing connections to the
            // Hermes instance. Ignored by the iOS SDK.
            "ENABLE_APP_SANDBOX": "YES",
            "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
            "ENABLE_HARDENED_RUNTIME": "YES",
        ].automaticCodeSigning(devTeam: developmentTeam)
    ),
    targets: [
        .target(
            name: "Hermes",
            destinations: [.iPhone, .iPad, .mac],
            product: .app,
            bundleId: bundleIdPrefix,
            deploymentTargets: deploymentTargets,
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Hermes",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:],
                "NSCameraUsageDescription": "Take a photo to send in a message.",
            ]),
            sources: ["App/Sources/**"],
            resources: ["App/Resources/**"],
            dependencies: [
                .package(product: "HermesAPI"),
                .package(product: "HermesSecurity"),
                .package(product: "HermesChat"),
            ]
        ),
        .target(
            name: "HermesTests",
            destinations: [.iPhone, .iPad, .mac],
            product: .unitTests,
            bundleId: "\(bundleIdPrefix).tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["App/Tests/**"],
            dependencies: [
                .target(name: "Hermes")
            ]
        ),
    ],
    schemes: [
        .scheme(
            name: "Hermes",
            shared: true,
            buildAction: .buildAction(targets: ["Hermes"]),
            testAction: .targets(["HermesTests"]),
            runAction: .runAction(executable: "Hermes")
        )
    ]
)
