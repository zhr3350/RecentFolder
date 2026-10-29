#!/usr/bin/env ruby
# 生成 RecentFolder.xcodeproj：单个主 App 目标（非沙盒，负责 AX 自动化）
require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'RecentFolder.xcodeproj')
DEPLOYMENT_TARGET = '14.0'

APP_NAME  = 'RecentFolder'
APP_BUNDLE_ID = 'com.haoran.recentfolder'

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastUpgradeCheck'] = '2700'

app_target = project.new_target(:application, APP_NAME, :osx, DEPLOYMENT_TARGET)

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
shared_group = sync_group(project, project.main_group, 'Shared', 'Shared')

def swift_refs(group)
  group.files.select { |r| r.path&.end_with?('.swift') }
end

def add_sources(target, refs)
  refs.each { |r| target.source_build_phase.add_file_reference(r) }
end

add_sources(app_target, swift_refs(app_group) + swift_refs(shared_group))

# ---------- 资源（应用图标）----------
resources_group = project.main_group.new_group('Resources', 'App/Resources')
icon_ref = resources_group.new_file('AppIcon.icns')
app_target.resources_build_phase.add_file_reference(icon_ref)

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

project.save
puts "已生成：#{PROJECT_PATH}"
