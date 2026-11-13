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
  spec.source           = { :git => 'https://github.com/faimin/ZDObf.git', :tag => "v#{spec.version}" }

  spec.ios.deployment_target = '15.0'
  spec.osx.deployment_target = '15.0'
  spec.tvos.deployment_target = '15.0'
  spec.watchos.deployment_target = '8.0'
  spec.visionos.deployment_target = '1.0'
  spec.module_name = 'ZDObfKit'
  spec.swift_versions = ['5.0', '6.0']
  spec.source_files = 'Apple/**/*.{h,mm,swift}'
  spec.public_header_files = 'Apple/ObjectiveC/*.h'
  spec.vendored_frameworks = 'dist/ZDObfRuntime.xcframework'
  # 仓库不跟踪 Runtime 二进制时，pod install 从固定的 GitHub Release 下载并校验 SHA-256。
  spec.prepare_command = 'test -d dist/ZDObfRuntime.xcframework || sh scripts/fetch_runtime.sh'
  spec.requires_arc = true
  spec.frameworks = 'Foundation'
  spec.preserve_paths = 'crates/runtime/include/*.h', 'scripts/*.sh', 'Generator/**/*', 'README.md'
  spec.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++'
  }

  # XCFramework 必须由发布流程预构建；Pod 安装与每次 App 构建均不编译 Rust。
end
