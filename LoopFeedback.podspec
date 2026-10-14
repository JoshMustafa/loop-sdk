Pod::Spec.new do |s|
  s.name          = 'LoopFeedback'
  s.version       = '0.1.0'
  s.summary       = 'Bug and feature reporter UI for Loop.'
  s.homepage      = 'https://github.com/JoshMustafa/loop-sdk'
  s.license       = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author        = 'Josh Mustafa'
  s.source        = { :git => 'https://github.com/JoshMustafa/loop-sdk.git', :tag => "v#{s.version}" }
  s.swift_version = '5.9'
  s.ios.deployment_target = '16.0'
  s.pod_target_xcconfig = { 'OTHER_SWIFT_FLAGS' => '-package-name Loop' }
  s.source_files  = 'ios/Sources/LoopFeedback/**/*.swift'
  s.resource_bundles = { 'LoopFeedback' => ['ios/Sources/LoopFeedback/PrivacyInfo.xcprivacy',
                                            'ios/Sources/LoopFeedback/Resources/Localizable.xcstrings'] }
  s.dependency 'LoopCore', s.version.to_s
end
