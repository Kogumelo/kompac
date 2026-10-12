// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "KompacCore", targets: ["KompacCore"]),
]
var targets: [Target] = [
    // Listagem, extração, prévia e correção de nomes, por cima do 7zz — sem UI, testável.
    .target(name: "KompacCore"),
    .testTarget(
        name: "KompacCoreTests",
        dependencies: ["KompacCore"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
// O app (AppKit + SwiftUI) só existe no Mac.
products.append(.executable(name: "Kompac", targets: ["Kompac"]))
targets.append(
    // Modo de linguagem 5: o NSDocument ainda não tem anotações completas de concorrência.
    .executableTarget(
        name: "Kompac",
        dependencies: ["KompacCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "Kompac",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
