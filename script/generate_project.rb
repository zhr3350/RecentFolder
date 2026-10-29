#!/usr/bin/env ruby
# 生成 RecentFolder.xcodeproj：主 App（非沙盒，负责 AX 自动化）+ Finder Sync 扩展（沙盒）
require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'RecentFolder.xcodeproj')
DEPLOYMENT_TARGET = '14.0'

APP_NAME  = 'RecentFolder'
EXT_NAME  = 'RecentFolderFinder'
APP_BUNDLE_ID = 'com.haoran.recentfolder'
EXT_BUNDLE_ID = 'com.haoran.recentfolder.finder'
APP_GROUP = 'group.com.haoran.recentfolder'

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastUpgradeCheck'] = '2700'

app_target = project.new_target(:application, APP_NAME, :osx, DEPLOYMENT_TARGET)
ext_target = project.new_target(:app_extension, EXT_NAME, :osx, DEPLOYMENT_TARGET)

# ---------- 文件分组（按目录自动扫描，新增源码无需改动本脚本）----------
# 每个顶层目录建一个扁平分组，文件路径相对顶层目录，避免嵌套分组路径叠加出错
def sync_group(project, parent, name, rel_dir)
  group = parent.new_group(name, rel_dir)
  abs_dir = File.join(ROOT, rel_dir)
  Dir.glob('**/*.swift', base: abs_dir).sort.each do |rel|
    group.new_file(rel)
  end
  group
end

app_group = sync_group(project, project.main_group, 'App', 'App')
ext_group = sync_group(project, project.main_group, 'FinderExtension', 'FinderExtension')
shared_group = sync_group(project, project.main_group, 'Shared', 'Shared')

def swift_refs(group)
  group.files.select { |r| r.path&.end_with?('.swift') }
end

def add_sources(target, refs)
  refs.each { |r| target.source_build_phase.add_file_reference(r) }
end

add_sources(app_target, swift_refs(app_group) + swift_refs(shared_group))
add_sources(ext_target, swift_refs(ext_group) + swift_refs(shared_group))

# ---------- 构建设置 ----------
COMMON = {
  'SWIFT_VERSION' => '5.0',
  'MACOSX_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'CODE_SIGN_STYLE' => 'Manual',
  'CODE_SIGN_IDENTITY' => '-',
  'DEVELOPMENT_TEAM' => '',
  'ENABLE_HARDENED_RUNTIME' => 'NO',
  'ALWAYS_SEARCH_USER_PATHS' => 'NO',
  'CLANG_ENABLE_MODULES' => 'YES',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
}.freeze

app_settings = COMMON.merge(
  'PRODUCT_NAME' => APP_NAME,
  'PRODUCT_BUNDLE_IDENTIFIER' => APP_BUNDLE_ID,
  'INFOPLIST_FILE' => 'App/Info.plist',
  'CODE_SIGN_ENTITLEMENTS' => 'App/RecentFolder.entitlements',
  'COMBINE_HIDPI_IMAGES' => 'YES',
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks',
)

ext_settings = COMMON.merge(
  'PRODUCT_NAME' => EXT_NAME,
  'PRODUCT_BUNDLE_IDENTIFIER' => EXT_BUNDLE_ID,
  'INFOPLIST_FILE' => 'FinderExtension/Info.plist',
  'CODE_SIGN_ENTITLEMENTS' => 'FinderExtension/FinderExtension.entitlements',
  'SKIP_INSTALL' => 'YES',
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../../../../Frameworks',
)

def apply(target, settings)
  target.build_configurations.each do |config|
    settings.each { |k, v| config.build_settings[k] = v }
    if config.name == 'Debug'
      config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone'
      config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
      config.build_settings['ONLY_ACTIVE_ARCH'] = 'YES'
    end
  end
end

apply(app_target, app_settings)
apply(ext_target, ext_settings)

# ---------- 嵌入扩展 ----------
embed = app_target.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = Xcodeproj::Constants::COPY_FILES_BUILD_PHASE_DESTINATIONS[:plug_ins]
build_file = embed.add_file_reference(ext_target.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
app_target.add_dependency(ext_target)

project.save
puts "已生成：#{PROJECT_PATH}"
puts "App Group：#{APP_GROUP}"
