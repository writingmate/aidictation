#!/usr/bin/env ruby
require 'xcodeproj'

project = Xcodeproj::Project.open('Whispermate.xcodeproj')

# Find WhisperMateShared target
shared_target = project.targets.find { |t| t.name == 'WhisperMateShared' }

if shared_target
  shared_target.build_configurations.each do |config|
    # Generate Info.plist automatically for the framework
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    config.build_settings['MARKETING_VERSION'] = '0.0.20'
    config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  end
  puts "✅ Fixed WhisperMateShared framework settings"
end

# Fix iOS app target for App Store distribution
ios_target = project.targets.find { |t| t.name == 'WhisperMateIOS' }
if ios_target
  ios_target.build_configurations.each do |config|
    config.build_settings['MARKETING_VERSION'] = '0.0.20'
    config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
    # Use manual code signing for App Store
    config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
    config.build_settings['DEVELOPMENT_TEAM'] = 'G7DJ6P37KU'
    if config.name == 'Release'
      config.build_settings['CODE_SIGN_IDENTITY'] = 'iPhone Distribution'
      config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = ''
    end
  end
  puts "✅ Fixed WhisperMateIOS app settings"
end

# Fix keyboard extension target
keyboard_target = project.targets.find { |t| t.name == 'WhisperMateKeyboard' }
if keyboard_target
  keyboard_target.build_configurations.each do |config|
    config.build_settings['MARKETING_VERSION'] = '0.0.20'
    config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
    config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
    config.build_settings['DEVELOPMENT_TEAM'] = 'G7DJ6P37KU'
    if config.name == 'Release'
      config.build_settings['CODE_SIGN_IDENTITY'] = 'iPhone Distribution'
      config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = ''
    end
  end
  puts "✅ Fixed WhisperMateKeyboard extension settings"
end

project.save
puts "\n💾 Project saved!"
