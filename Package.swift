// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Cropper", platforms: [.macOS(.v14)], products: [.executable(name: "Cropper", targets: ["Cropper"])], targets: [.executableTarget(name: "Cropper"), .testTarget(name: "CropperTests", dependencies: ["Cropper"])])
