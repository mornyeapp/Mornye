#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint audioplayers.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'audioplayers_darwin'
  s.version          = '0.0.1'
  s.summary          = 'Flutter Audioplayers Plugin'
  s.description      = 'Darwin implementation of audioplayers, a Flutter plugin to play multiple audio files simultaneously.'
  s.homepage         = 'https://github.com/bluefireteam/audioplayers'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Blue Fire' => 'contact@blue-fire.xyz' }
  s.source           = { :path => '.' }
  s.documentation_url = 'https://pub.dev/packages/audioplayers'
  s.source_files = 'audioplayers_darwin/Sources/audioplayers_darwin/**/*.swift'
  s.frameworks = 'AVFoundation', 'AudioToolbox', 'MediaToolbox'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
