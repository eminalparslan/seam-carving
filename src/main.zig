const std = @import("std");
const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("glad/gl.h");
    @cInclude("GLFW/glfw3.h");
});

fn glErrorCallback(err: c_int, desc: [*c]const u8) callconv(.C) void {
    std.log.err("GLFW error {d}: {s}\n", .{ err, desc });
}

fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = scancode;
    _ = mods;
    if (key == c.GLFW_KEY_ESCAPE and action == c.GLFW_PRESS) {
        c.glfwSetWindowShouldClose(window, c.GLFW_TRUE);
    }
}

const Image = struct {
    width: usize,
    height: usize,
    channels: usize,
    size: usize,
    data: []u8,

    fn init(path: [*c]const u8) !Image {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var channels: c_int = undefined;
        const data = c.stbi_load(path, &width, &height, &channels, 0);
        if (data == null) {
            return error.InvalidInput;
        }

        const size: usize = @intCast(width * height * channels);

        return Image{
            .width = @intCast(width),
            .height = @intCast(height),
            .channels = @intCast(channels),
            .size = size,
            .data = data[0..size],
        };
    }

    fn deinit(self: *const Image) void {
        c.stbi_image_free(@ptrCast(self.data.ptr));
    }
};

fn imageToTexture(image: Image) !c.GLuint {
    var texture: c.GLuint = undefined;
    c.glGenTextures(1, &texture);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);

    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    if (image.channels == 3) {
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGB, @intCast(image.width), @intCast(image.height), 0, c.GL_RGB, c.GL_UNSIGNED_BYTE, image.data.ptr);
    } else if (image.channels == 4) {
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, @intCast(image.width), @intCast(image.height), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, image.data.ptr);
    } else {
        std.log.err("Unsupported number of channels: {d}\n", .{image.channels});
        return error.InvalidInput;
    }

    c.glGenerateMipmap(c.GL_TEXTURE_2D);

    return texture;
}

pub fn main() !void {
    const image: Image = try Image.init("Broadway_tower_edit.jpg");
    defer image.deinit();

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

    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 2);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 1);
    c.glfwWindowHint(c.GLFW_SAMPLES, 16);

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

    _ = c.glfwSetKeyCallback(window, keyCallback);

    // vsync
    c.glfwSwapInterval(1);
    // debug output
    c.glEnable(c.GL_DEBUG_OUTPUT);
    // not available in OpenGL 4.1, which is the highest version on MacOS
    // c.glDebugMessageCallback(glDebugCallback, null);

    // c.glClearColor(0.2, 0.3, 0.3, 1.0);
    c.glClearColor(0.0, 0.0, 0.0, 1.0);

    const texture = try imageToTexture(image);
    defer c.glDeleteTextures(1, &texture);

    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        // framebuffer size
        var fb_width: c_int = undefined;
        var fb_height: c_int = undefined;
        const fb_width_f: f32 = @floatFromInt(fb_width);
        const fb_height_f: f32 = @floatFromInt(fb_height);
        c.glfwGetFramebufferSize(window, &fb_width, &fb_height);
        c.glViewport(0, 0, fb_width, fb_height);

        c.glClear(c.GL_COLOR_BUFFER_BIT);

        c.glEnable(c.GL_TEXTURE_2D);

        // c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, texture);

        c.glMatrixMode(c.GL_PROJECTION);
        c.glLoadIdentity();
        c.glOrtho(0, fb_width_f, fb_height_f, 0, -1, 1);

        c.glMatrixMode(c.GL_MODELVIEW);
        c.glLoadIdentity();

        c.glBegin(c.GL_QUADS);
        c.glTexCoord2f(0.0, 0.0);
        c.glVertex2f(0.0, 0.0);
        c.glTexCoord2f(1.0, 0.0);
        c.glVertex2f(fb_width_f, 0.0);
        c.glTexCoord2f(1.0, 1.0);
        c.glVertex2f(fb_width_f, fb_height_f);
        c.glTexCoord2f(0.0, 1.0);
        c.glVertex2f(0.0, fb_height_f);
        c.glEnd();

        c.glfwSwapBuffers(window);
        c.glfwPollEvents();
    }

    std.debug.print("Goodbye, world!\n", .{});
}
