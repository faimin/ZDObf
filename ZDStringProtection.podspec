Pod::Spec.new do |spec|
  spec.name             = 'ZDStringProtection'
  spec.version          = '0.1.0'
  spec.summary          = 'Mach-O embedded encrypted string runtime for iOS.'
  spec.description      = <<-DESC
    Provides the Objective-C and Swift wrappers for a prebuilt Rust runtime.
    App-specific encrypted string data is generated during the App build and
    embedded in the final Mach-O image, never in this pod or XCFramework.
  DESC
  spec.license          = 'MIT'
  spec.author           = 'Zero.D.Saber'
  spec.homepage         = 'https://github.com/faimin/ZDObf'
  spec.source           = { :git => 'https://github.com/faimin/ZDObf.git', :tag => spec.version.to_s }

  spec.ios.deployment_target = '13.0'
  spec.module_name = spec.name
  spec.source_files = 'Apple/**/*.{h,mm,swift}'
  spec.public_header_files = 'Apple/ObjectiveC/*.h'
  spec.vendored_frameworks = 'dist/ZDStringProtectionRuntime.xcframework'
  spec.requires_arc = true
  spec.frameworks = 'Foundation'
  spec.preserve_paths = 'crates/runtime/include/*.h', 'scripts/*.sh', 'Generator/**/*', 'README.md'
  spec.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++'
  }

  # XCFramework 必须由发布流程预构建；Pod 安装与每次 App 构建均不编译 Rust。
end
