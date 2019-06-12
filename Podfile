# Uncomment the next line to define a global platform for your project
platform :ios, '11.0'

target 'VanProximity' do
  # Comment the next line if you're not using Swift and don't want to use dynamic frameworks
  use_frameworks!

  # Pods for VanProximity
  pod 'RxBluetoothKit'
  pod 'RxCoreLocation'

  target 'VanProximityTests' do
    inherit! :search_paths
    # Pods for testing
  end

  target 'VanProximityUITests' do
    inherit! :search_paths
    # Pods for testing
  end

end

post_install do |installer_representation|
  # So that every pod gets Testability enabled on UnitTest builds.
  installer_representation.pods_project.targets.each do |target|
    target.build_configurations.each do |config|

      config.build_settings['SWIFT_VERSION'] = '5.0'

    end
  end
end
