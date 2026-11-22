Pod::Spec.new do |s|
  s.name             = 'ffmpeg_kit_flutter_new_audio'
  s.version          = '8.1.3'
  s.summary          = 'FFmpeg Kit for Flutter'
  s.description      = 'A Flutter plugin for running FFmpeg and FFprobe commands.'
  s.homepage         = 'https://github.com/sk3llo/ffmpeg_kit_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Anton Karpenko' => 'kapraton@gmail.com' }

  s.platform            = :osx
  s.requires_arc        = true
  s.static_framework    = true

  s.source              = { :path => '.' }
  s.source_files        = 'ffmpeg_kit_flutter_new_audio/Sources/ffmpeg_kit_flutter_new_audio/**/*.{h,m}'
  s.public_header_files = 'ffmpeg_kit_flutter_new_audio/Sources/ffmpeg_kit_flutter_new_audio/include/**/*.h'

  s.default_subspec     = 'audio'

  s.dependency          'FlutterMacOS'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  s.subspec 'audio' do |ss|
    ss.source_files         = 'ffmpeg_kit_flutter_new_audio/Sources/ffmpeg_kit_flutter_new_audio/**/*.{h,m}'
    ss.public_header_files  = 'ffmpeg_kit_flutter_new_audio/Sources/ffmpeg_kit_flutter_new_audio/include/**/*.h'
    ss.osx.vendored_frameworks = 'Frameworks/ffmpegkit.framework',
                                 'Frameworks/libavcodec.framework',
                                 'Frameworks/libavdevice.framework',
                                 'Frameworks/libavfilter.framework',
                                 'Frameworks/libavformat.framework',
                                 'Frameworks/libavutil.framework',
                                 'Frameworks/libswresample.framework',
                                 'Frameworks/libswscale.framework'
    ss.osx.deployment_target = '11.0'

    # Adding pre-install hook for macOS
    s.prepare_command = <<-CMD
      if [ ! -d "./Frameworks/ffmpegkit.framework" ]; then
        chmod +x ../scripts/setup_macos.sh
        ../scripts/setup_macos.sh
      fi
    CMD
  end
end
