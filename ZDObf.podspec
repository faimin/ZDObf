Pod::Spec.new do |spec|
  spec.name             = 'ZDObf'
  spec.version          = '0.1.0'
  spec.summary          = 'Mach-O embedded encrypted string runtime for Apple platforms.'
  spec.description      = <<-DESC
    Provides the Objective-C and Swift wrappers for a prebuilt Rust runtime.
    App-specific encrypted string data is generated during the App build and
    embedded in the final Mach-O image, never in this pod or XCFramework.
  DESC
  spec.license          = 'MIT'
  spec.author           = 'Zero.D.Saber'
  spec.homepage         = 'https://github.com/faimin/ZDObf'
  spec.source           = { :git => 'https://github.com/faimin/ZDObf.git', :tag => spec.version.to_s }

  spec.ios.deployment_target = '15.0'
  spec.osx.deployment_target = '15.0'
  spec.tvos.deployment_target = '15.0'
  spec.watchos.deployment_target = '8.0'
  spec.visionos.deployment_target = '1.0'
  spec.module_name = spec.name
  spec.source_files = 'Apple/**/*.{h,mm,swift}'
  spec.public_header_files = 'Apple/ObjectiveC/*.h'
  spec.vendored_frameworks = 'dist/ZDObfRuntime.xcframework'
  spec.requires_arc = true
  spec.frameworks = 'Foundation'
  spec.preserve_paths = 'crates/runtime/include/*.h', 'scripts/*.sh', 'Generator/**/*', 'README.md'
  spec.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++'
  }

  # XCFramework 必须由发布流程预构建；Pod 安装与每次 App 构建均不编译 Rust。
end
