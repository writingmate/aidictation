#!/usr/bin/env ruby
require 'xcodeproj'

project = Xcodeproj::Project.open('Whispermate.xcodeproj')

# Main app target - use the first occurrence
ios_target = project.targets.find { |t| t.name == 'WhisperMateIOS' }
if ios_target
  ios_target.build_configurations.each do |config|
    config.build_settings['DEVELOPMENT_TEAM'] = 'G7DJ6P37KU'
    if config.name == 'Release'
      config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
      config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = '7b2401f4-a895-490b-9743-d5302342c4d2'
      config.build_settings['CODE_SIGN_IDENTITY'] = 'iPhone Distribution'
      puts "✅ Configured WhisperMateIOS for manual signing (Release)"
    end
  end
end

# Keyboard extension - use the first occurrence
keyboard_target = project.targets.find { |t| t.name == 'WhisperMateKeyboard' }
if keyboard_target
  keyboard_target.build_configurations.each do |config|
    config.build_settings['DEVELOPMENT_TEAM'] = 'G7DJ6P37KU'
    if config.name == 'Release'
      config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
      config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = '2bdbec39-a1a0-4704-8592-6a528eb6fa01'
      config.build_settings['CODE_SIGN_IDENTITY'] = 'iPhone Distribution'
      puts "✅ Configured WhisperMateKeyboard for manual signing (Release)"
    end
  end
end

project.save
puts "\n💾 Project saved with manual signing configuration!"
