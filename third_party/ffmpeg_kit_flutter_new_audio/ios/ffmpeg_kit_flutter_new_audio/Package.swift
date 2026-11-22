// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// FFmpeg 8.1.3 audio prebuilt binaries.
// Each zip contains one combined XCFramework with ios-arm64 (arm64e dropped, #164),
// ios-arm64_x86_64-simulator and macos-arm64_x86_64 slices, each with its dSYM.
// URLs and checksums are regenerated on every native FFmpeg release
// (see scripts/build_spm_artifacts.sh).
let ffmpegTag = "8.1.3-audio"
let ffmpegBase = "https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/\(ffmpegTag)"
let ffmpegLibs: [(name: String, checksum: String)] = [
    ("ffmpegkit", "b87de3a18b44d0f09c3958b422b6e7a685bc000d93c24b2281cbca059987cb4c"),
    ("libavcodec", "ec32e875dfaebaaf62dd7bdc8fe35c7ac1fdbb4d73be4e2a88e0b8aeefc8f568"),
    ("libavdevice", "d23104d50fbb4dba52a91297b487234b9e245c7070affd5e1d78bef32e971334"),
    ("libavfilter", "1566b4fec0c6cf5f70b65d8dcefd98d0fc53dcbcc950517de84412a708b176d4"),
    ("libavformat", "82fb5d5c305fb1fbdbe9d0c5b4f2f7e0c8f9b7dd2a50872f4a4e3cd1351e66ad"),
    ("libavutil", "793968cd21fbdf794597b48de443aafc394658fe75e41d03c0a0790b7215241b"),
    ("libswresample", "a50f75df11b4c823b0a2cd13414cb28ad51c1d2fc88f7a1a911f8e10ac72e1b0"),
    ("libswscale", "906abbe0cff98373a136de0502c614e2a63925ed879951d1b70b9cec28c3ddf8"),
]

let package = Package(
    name: "ffmpeg_kit_flutter_new_audio",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "ffmpeg-kit-flutter-new-audio", targets: ["ffmpeg_kit_flutter_new_audio"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: ffmpegLibs.map { lib in
        .binaryTarget(
            name: lib.name,
            url: "\(ffmpegBase)/\(lib.name).xcframework.zip",
            checksum: lib.checksum
        )
    } + [
        .target(
            name: "ffmpeg_kit_flutter_new_audio",
            dependencies: ffmpegLibs.map { .target(name: $0.name) } + [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            cSettings: [
                .headerSearchPath("include/ffmpeg_kit_flutter_new_audio")
            ]
        )
    ]
)
