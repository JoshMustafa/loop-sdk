Pod::Spec.new do |s|
  s.name             = 'loop_analytics'
  s.version          = '2.0.0'
  s.summary          = 'Loop product analytics for Flutter, backed by the native Loop SDK.'
  s.homepage         = 'https://github.com/JoshMustafa/loop-sdk'
  s.license          = { :type => 'Proprietary', :file => '../LICENSE' }
  s.author           = 'Josh Mustafa'
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform         = :ios, '16.0'
  s.swift_version    = '5.9'

  # The native LoopCore and LoopAnalytics modules are compiled from the
  # monorepo checkout. CocoaPods only globs files under this directory and
  # does not descend into symlinked directories, so Classes/Vendor holds a
  # per-file symlink to each native source (tool/link_native_sources.sh).
  s.source_files = [
    'Classes/*.swift',
    'Classes/Vendor/LoopCore/**/*.swift',
    'Classes/Vendor/LoopAnalytics/**/*.swift',
  ]
  s.resource_bundles = {
    'LoopCore_privacy' => ['Classes/Vendor/LoopCore/PrivacyInfo.xcprivacy'],
    'LoopAnalytics_privacy' => ['Classes/Vendor/LoopAnalytics/PrivacyInfo.xcprivacy'],
  }
  s.libraries = 'z'

  # Both native modules compile into this pod's single module, so the
  # LoopAnalytics sources' `import LoopCore` is aliased to it (Swift then
  # ignores the import, with a warning). `package` declarations need the
  # native build's package name.
  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_SWIFT_FLAGS' => '$(inherited) -package-name Loop -module-alias LoopCore=loop_analytics',
  }
end
