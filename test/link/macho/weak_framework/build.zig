const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjectStep = std.build.LibExeObjStep;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Test the program");
    test_step.dependOn(b.getInstallStep());

    const exe = b.addExecutable("test", null);
    exe.addCSourceFile("main.c", &[0][]const u8{});
    exe.setBuildMode(mode);
    exe.linkLibC();
    exe.linkFrameworkWeak("Cocoa");

    const check_exe = exe.checkObject(.macho, .{});
    const check = check_exe.root();
    check.match("cmd LOAD_WEAK_DYLIB");
    check.match("name {*}Cocoa");
    test_step.dependOn(&check_exe.step);

    const run_cmd = exe.run();
    test_step.dependOn(&run_cmd.step);
}
