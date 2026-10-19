Pod::Spec.new do |s|
  s.name = 'lrdp_native'
  s.version = '0.1.0'
  s.summary = 'LRDP FreeRDP bridge'
  s.description = 'An isolated FreeRDP bridge with a versioned C ABI.'
  s.homepage = 'https://github.com/FreeRDP/FreeRDP'
  s.license = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author = 'LRDP contributors'
  s.source = { :path => '.' }
  s.vendored_frameworks = 'Frameworks/LRDP.xcframework'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
