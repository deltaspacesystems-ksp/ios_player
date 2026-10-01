# Injects the LumenKit framework target into VLC's Xcode project and adds a "Lumen" tab.
require 'xcodeproj'

root = ARGV[0] or abort 'usage: patch_vlc.rb <vlc-src>'
project = Xcodeproj::Project.open(File.join(root, 'VLC.xcodeproj'))
app = project.targets.find { |t| t.name == 'VLC-iOS-no-watch' } or abort 'app target not found'

kit = project.new_target(:framework, 'LumenKit', :ios, '26.0')
kit.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'dev.lumen.player.kit'
  s['PRODUCT_NAME'] = 'LumenKit'
  s['PRODUCT_MODULE_NAME'] = 'LumenKit'
  s['SWIFT_OBJC_BRIDGING_HEADER'] = ''
  s['CLANG_ENABLE_MODULES'] = 'YES'
  s['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  s['OTHER_SWIFT_FLAGS'] = ''
  s['SWIFT_VERSION'] = '5.0'
  s['DEFINES_MODULE'] = 'YES'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SKIP_INSTALL'] = 'YES'
  s['MARKETING_VERSION'] = '1.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
end

group = project.main_group.new_group('LumenKit', 'LumenKit')
Dir[File.join(root, 'LumenKit', '*.swift')].sort.each do |f|
  ref = group.new_file(File.basename(f))
  kit.add_file_references([ref])
end

app.add_dependency(kit)
app.frameworks_build_phase.add_file_reference(kit.product_reference, true)
embed = app.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :frameworks }
embed ||= app.new_copy_files_build_phase('Embed Frameworks').tap { |p| p.symbol_dst_subfolder_spec = :frameworks }
bf = embed.add_file_reference(kit.product_reference, true)
bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }

project.save
puts "LumenKit target injected (#{kit.source_build_phase.files.count} sources)"

# --- add the tab ---
tbc_path = File.join(root, 'Sources/App/iOS/TabBarCoordinator.swift')
tbc = File.read(tbc_path)
abort 'import UIKit not found' unless tbc.sub!(/^import UIKit$/, "import UIKit\nimport LumenKit")
anchor = "        controllers.append(onAirNavigationController)\n"
abort 'anchor not found' unless tbc.include?(anchor)
tbc.sub!(anchor, anchor + <<~SWIFT)

        if #available(iOS 26.0, *) {
            LumenKit.onWillPlay = { PlaybackService.sharedInstance().pause() }
            let lumen = UINavigationController(rootViewController: LumenKit.makeViewController())
            lumen.isNavigationBarHidden = true
            controllers.append(lumen)
        }
SWIFT
File.write(tbc_path, tbc)
puts 'Lumen tab added to TabBarCoordinator'
