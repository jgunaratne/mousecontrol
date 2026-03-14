#!/usr/bin/env ruby
# Generate the MouseControl.xcodeproj using the xcodeproj gem.
# Run: ruby generate_project.rb

require 'xcodeproj'

project_path = File.join(__dir__, 'MouseControl.xcodeproj')
project = Xcodeproj::Project.new(project_path)

# --- Build Configuration ---
project.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.junius.mousecontrol'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['INFOPLIST_FILE'] = 'MouseControl/Info.plist'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'MouseControl/MouseControl.entitlements'
  config.build_settings['ENABLE_APP_SANDBOX'] = 'NO'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['PRODUCT_NAME'] = 'MouseControl'
  config.build_settings['COMBINE_HIDPI_IMAGES'] = 'YES'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
end

# --- Native Target ---
target = project.new_target(:application, 'MouseControl', :osx, '13.0')

target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.junius.mousecontrol'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['INFOPLIST_FILE'] = 'MouseControl/Info.plist'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'MouseControl/MouseControl.entitlements'
  config.build_settings['ENABLE_APP_SANDBOX'] = 'NO'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['PRODUCT_NAME'] = 'MouseControl'
  config.build_settings['COMBINE_HIDPI_IMAGES'] = 'YES'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/../Frameworks'
end

# --- Groups ---
main_group = project.main_group
mousecontrol_group = main_group.new_group('MouseControl', 'MouseControl')
core_group = mousecontrol_group.new_group('Core', 'Core')
network_group = mousecontrol_group.new_group('Network', 'Network')
ui_group = mousecontrol_group.new_group('UI', 'UI')

# --- Source Files ---
source_files = {
  mousecontrol_group => [
    'MouseControl/MouseControlApp.swift',
    'MouseControl/AppDelegate.swift',
  ],
  core_group => [
    'MouseControl/Core/ControlEvent.swift',
    'MouseControl/Core/AIManager.swift',
  ],
  network_group => [
    'MouseControl/Network/TCPManager.swift',
  ],
  ui_group => [
    'MouseControl/UI/PromptView.swift',
    'MouseControl/UI/StatusBarController.swift',
  ],
}

source_files.each do |group, paths|
  paths.each do |path|
    file_ref = group.new_reference(File.basename(path))
    file_ref.set_path(File.basename(path))
    target.source_build_phase.add_file_reference(file_ref)
  end
end

# --- Asset Catalog ---
assets_ref = mousecontrol_group.new_reference('Assets.xcassets')
target.resources_build_phase.add_file_reference(assets_ref)

# --- Resource/Config Files (not compiled, just referenced) ---
info_ref = mousecontrol_group.new_reference('Info.plist')
entitlements_ref = mousecontrol_group.new_reference('MouseControl.entitlements')

project.save

puts "✅ MouseControl.xcodeproj generated successfully!"
