Pod::Spec.new do |s|
  s.name          = 'LoopCore'
  s.version       = '2.0.0'
  s.summary       = 'Shared configuration, identity and networking for the Loop SDK.'
  s.homepage      = 'https://github.com/JoshMustafa/loop-sdk'
  s.license       = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author        = 'Josh Mustafa'
  s.source        = { :git => 'https://github.com/JoshMustafa/loop-sdk.git', :tag => s.version.to_s }
  s.swift_version = '5.9'
  s.ios.deployment_target = '16.0'
  s.pod_target_xcconfig = { 'OTHER_SWIFT_FLAGS' => '-package-name Loop' }
  s.source_files  = 'ios/Sources/LoopCore/**/*.swift'
  s.libraries     = 'z'
  s.resource_bundles = { 'LoopCore' => ['ios/Sources/LoopCore/PrivacyInfo.xcprivacy'] }
end
