Pod::Spec.new do |s|
  s.name             = 'ffmpeg_kit_flutter_new_audio'
  s.version          = '8.1.3'
  s.summary          = 'FFmpeg Kit for Flutter'
  s.description      = 'A Flutter plugin for running FFmpeg and FFprobe commands.'
  s.homepage         = 'https://github.com/sk3llo/ffmpeg_kit_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Anton Karpenko' => 'kapraton@gmail.com' }

  s.platform            = :ios
  s.requires_arc        = true
  s.static_framework    = true

  s.source              = { :path => '.' }
  s.source_files        = 'ffmpeg_kit_flutter_new_audio/Sources/ffmpeg_kit_flutter_new_audio/**/*.{h,m}'
  s.public_header_files = 'ffmpeg_kit_flutter_new_audio/Sources/ffmpeg_kit_flutter_new_audio/include/**/*.h'

  s.default_subspec = 'audio'

  s.dependency          'Flutter'
  # The vendored xcframeworks ship a native arm64 iOS-simulator slice, so arm64
  # must NOT be excluded for the simulator (required by Apple Silicon / Xcode 26+).
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }

  s.subspec 'audio' do |ss|
    s.prepare_command = <<-CMD
      if [ ! -d "./Frameworks/ffmpegkit.xcframework" ]; then
        chmod +x ../scripts/setup_ios.sh
        ../scripts/setup_ios.sh
        fi
    CMD
    ss.source_files         = 'ffmpeg_kit_flutter_new_audio/Sources/ffmpeg_kit_flutter_new_audio/**/*.{h,m}'
    ss.public_header_files  = 'ffmpeg_kit_flutter_new_audio/Sources/ffmpeg_kit_flutter_new_audio/include/**/*.h'
    ss.ios.vendored_frameworks = 'Frameworks/ffmpegkit.xcframework',
                                 'Frameworks/libavcodec.xcframework',
                                 'Frameworks/libavdevice.xcframework',
                                 'Frameworks/libavfilter.xcframework',
                                 'Frameworks/libavformat.xcframework',
                                 'Frameworks/libavutil.xcframework',
                                 'Frameworks/libswresample.xcframework',
                                 'Frameworks/libswscale.xcframework'
    ss.ios.deployment_target = '15.0'
  end
end
