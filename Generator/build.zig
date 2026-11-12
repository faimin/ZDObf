const std = @import("std");

// Zig 只构建编排器，不链接或复制 Rust 密码学实现。

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const executable = b.addExecutable(.{ .name = "zdstring-gen", .root_module = module });
    b.installArtifact(executable);

    // 暴露 Zig 单元测试步骤，CI 与本地验证使用同一构建入口。
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zdstring generator tests");
    test_step.dependOn(&run_tests.step);
}
