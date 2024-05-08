const std = @import("std");
const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("glad/gl.h");
    @cInclude("GLFW/glfw3.h");
});

fn glErrorCallback(err: c_int, desc: [*c]const u8) callconv(.C) void {
    std.log.err("GLFW error {d}: {s}\n", .{ err, desc });
}

pub fn main() !void {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;
    const image: [*c]u8 = c.stbi_load("Broadway_tower_edit.jpg", &width, &height, &channels, 0);
    if (image == null) {
        std.log.err("Failed to load image!\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    _ = alloc;

    if (c.glfwInit() == c.GLFW_FALSE) {
        std.log.err("Failed to initialize GLFW!\n", .{});
        return error.Initialization;
    }
    defer c.glfwTerminate();

    _ = c.glfwSetErrorCallback(glErrorCallback);

    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 4);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 1);

    const window = c.glfwCreateWindow(640, 480, "Title", null, null) orelse {
        std.log.err("Failed to create window!\n", .{});
        return error.Initialization;
    };
    defer c.glfwDestroyWindow(window);

    c.glfwMakeContextCurrent(window);
    if (c.gladLoadGL(c.glfwGetProcAddress) == 0) {
        std.log.err("Failed to load OpenGL!\n", .{});
        return error.Initialization;
    }

    // vsync
    c.glfwSwapInterval(1);
    // debug output
    c.glEnable(c.GL_DEBUG_OUTPUT);
    // not available in OpenGL 4.1, which is the highest version on MacOS
    // c.glDebugMessageCallback(glDebugCallback, null);

    // TODO: glfwSetWindowShouldClose on escape key
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        c.glClearColor(0.2, 0.3, 0.3, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        c.glfwSwapBuffers(window);
        c.glfwPollEvents();
    }

    std.debug.print("Image: width={}, height={}!\n", .{ width, height });
}
