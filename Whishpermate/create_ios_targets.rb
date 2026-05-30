#!/usr/bin/env ruby

# This script uses the xcodeproj gem to programmatically add iOS targets
# Install with: gem install xcodeproj

require 'xcodeproj'

PROJECT_PATH = 'Whispermate.xcodeproj'
APP_GROUP_ID = 'group.com.whispermate.shared'

puts "🎯 Creating iOS targets for WhisperMate..."
puts "=" * 50

# Open the project
project = Xcodeproj::Project.open(PROJECT_PATH)

# Get the main group
main_group = project.main_group

# Create groups for new targets
puts "\n📁 Creating project groups..."
shared_group = main_group.new_group('WhisperMateShared')
ios_group = main_group.new_group('WhisperMateIOS')
keyboard_group = main_group.new_group('WhisperMateKeyboard')

# STEP 1: Create WhisperMateShared Framework Target
puts "\n🔨 Creating WhisperMateShared framework target..."
shared_target = project.new_target(:framework, 'WhisperMateShared', :ios, '15.0')

# Add files to shared framework
puts "  Adding shared files..."
['Models', 'Networking', 'Services', 'Storage'].each do |folder|
  folder_path = "WhisperMateShared/#{folder}"
  if Dir.exist?(folder_path)
    folder_group = shared_group.new_group(folder)
    Dir.glob("#{folder_path}/*.swift").each do |file|
      file_ref = folder_group.new_file(file)
      shared_target.source_build_phase.add_file_reference(file_ref)
    end
  end
end

# Configure framework settings
shared_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'WhisperMateShared'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.whispermate.shared'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['DEFINES_MODULE'] = 'YES'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1' # iPhone only
end

# STEP 2: Create WhisperMateIOS App Target
puts "\n📱 Creating WhisperMateIOS app target..."
ios_target = project.new_target(:application, 'WhisperMateIOS', :ios, '15.0')

# Add files to iOS app
puts "  Adding iOS app files..."
['WhisperMateApp.swift', 'OnboardingView.swift', 'MainView.swift'].each do |filename|
  file_path = "WhisperMateIOS/#{filename}"
  if File.exist?(file_path)
    file_ref = ios_group.new_file(file_path)
    ios_target.source_build_phase.add_file_reference(file_ref)
  end
end

# Add Info.plist
info_plist = ios_group.new_file('WhisperMateIOS/Info.plist')

# Link framework to iOS app
puts "  Linking WhisperMateShared framework..."
ios_target.frameworks_build_phase.add_file_reference(shared_target.product_reference)
ios_target.add_dependency(shared_target)

# Configure iOS app settings
ios_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'WhisperMate'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.whispermate.ios'
  config.build_settings['INFOPLIST_FILE'] = 'WhisperMateIOS/Info.plist'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'WhisperMateIOS/WhisperMateIOS.entitlements'
end

# STEP 3: Create WhisperMateKeyboard Extension Target
puts "\n⌨️  Creating WhisperMateKeyboard extension target..."
keyboard_target = project.new_target(:app_extension, 'WhisperMateKeyboard', :ios, '15.0')

# Add files to keyboard extension
puts "  Adding keyboard extension files..."
['KeyboardViewController.swift'].each do |filename|
  file_path = "WhisperMateKeyboard/#{filename}"
  if File.exist?(file_path)
    file_ref = keyboard_group.new_file(file_path)
    keyboard_target.source_build_phase.add_file_reference(file_ref)
  end
end

# Add Info.plist
keyboard_info_plist = keyboard_group.new_file('WhisperMateKeyboard/Info.plist')

# Link framework to keyboard extension
puts "  Linking WhisperMateShared framework..."
keyboard_target.frameworks_build_phase.add_file_reference(shared_target.product_reference)
keyboard_target.add_dependency(shared_target)

# Configure keyboard extension settings
keyboard_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'WhisperMateKeyboard'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.whispermate.ios.keyboard'
  config.build_settings['INFOPLIST_FILE'] = 'WhisperMateKeyboard/Info.plist'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'WhisperMateKeyboard/WhisperMateKeyboard.entitlements'
end

# Add keyboard extension to iOS app
ios_target.add_dependency(keyboard_target)
copy_files_phase = ios_target.new_copy_files_build_phase('Embed App Extensions')
copy_files_phase.dst_subfolder_spec = '13' # PlugIns
copy_files_phase.add_file_reference(keyboard_target.product_reference)

# Create entitlements files
puts "\n🔐 Creating entitlements files..."

# iOS App Entitlements
ios_entitlements_content = <<~XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>com.apple.security.application-groups</key>
\t<array>
\t\t<string>#{APP_GROUP_ID}</string>
\t</array>
</dict>
</plist>
XML

File.write('WhisperMateIOS/WhisperMateIOS.entitlements', ios_entitlements_content)
ios_group.new_file('WhisperMateIOS/WhisperMateIOS.entitlements')

# Keyboard Extension Entitlements
keyboard_entitlements_content = <<~XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>com.apple.security.application-groups</key>
\t<array>
\t\t<string>#{APP_GROUP_ID}</string>
\t</array>
</dict>
</plist>
XML

File.write('WhisperMateKeyboard/WhisperMateKeyboard.entitlements', keyboard_entitlements_content)
keyboard_group.new_file('WhisperMateKeyboard/WhisperMateKeyboard.entitlements')

# Create schemes
puts "\n📋 Creating schemes..."

# WhisperMateIOS scheme
ios_scheme = Xcodeproj::XCScheme.new
ios_scheme.add_build_target(ios_target)
ios_scheme.set_launch_target(ios_target)
ios_scheme.save_as(project.path, 'WhisperMateIOS')

# Save the project
puts "\n💾 Saving project..."
project.save

puts "\n✅ iOS targets created successfully!"
puts "\n📋 Created targets:"
puts "  - WhisperMateShared (Framework)"
puts "  - WhisperMateIOS (App)"
puts "  - WhisperMateKeyboard (Extension)"
puts "\n🚀 Next steps:"
puts "  1. Open Whispermate.xcodeproj in Xcode"
puts "  2. Select WhisperMateIOS scheme"
puts "  3. Build (⌘B) to verify everything works"
puts "  4. Run on a physical device (keyboard extensions don't work in simulator)"
