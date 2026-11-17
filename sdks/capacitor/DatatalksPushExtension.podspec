require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# For the app's notification service extension target (pictures and delivery receipts). The app's Podfile adds it to that target
# itself, since Capacitor's CLI only writes the App target's pods. No Capacitor dependency: an extension can't link the app's
# runtime. It compiles the iOS SDK's extension sources (ios/Extension), which scripts/vendor-native.mjs copies in before packing.
Pod::Spec.new do |s|
  s.name = 'DatatalksPushExtension'
  s.module_name = 'DataTalksPushExtension'
  s.version = package['version']
  s.summary = 'Data Talks push: the notification service extension of a Capacitor app (pictures and delivery receipts).'
  s.license = package['license']
  s.homepage = package['repository']['url']
  s.author = package['author']
  s.source = { :git => package['repository']['url'], :tag => package['version'] }
  s.source_files = 'ios/Extension/**/*.swift'
  s.resource_bundles = { 'DatatalksPushExtensionPrivacy' => ['ios/Extension/PrivacyInfo.xcprivacy'] }
  s.ios.deployment_target = '14.0'
  s.swift_version = '5.9'
end
