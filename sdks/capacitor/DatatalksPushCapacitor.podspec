require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# Capacitor's Podfile references this pod by :path in node_modules, so it isn't published to CocoaPods trunk. It compiles the
# iOS SDK's sources (ios/Sources/DataTalksPushPlugin/Core), which scripts/vendor-native.mjs copies in before packing.
Pod::Spec.new do |s|
  s.name = 'DatatalksPushCapacitor'
  s.version = package['version']
  s.summary = package['description']
  s.license = package['license']
  s.homepage = package['repository']['url']
  s.author = package['author']
  s.source = { :git => package['repository']['url'], :tag => package['version'] }
  s.source_files = 'ios/Sources/**/*.swift'
  s.resource_bundles = { 'DatatalksPushCapacitorPrivacy' => ['ios/Sources/DataTalksPushPlugin/Core/PrivacyInfo.xcprivacy'] }
  s.ios.deployment_target = '14.0'
  s.dependency 'Capacitor'
  s.swift_version = '5.9'
end
