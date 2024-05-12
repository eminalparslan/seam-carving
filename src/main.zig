const std = @import("std");
const assert = @import("std").debug.assert;
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
    stride: usize,

    seamImageData: ?[]u32 = null,

    fn initImageFromFile(alloc: anytype, path: [*c]const u8) !Image {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var channels: c_int = undefined;
        const imageDataPtr = c.stbi_load(path, &width, &height, &channels, 0);
        if (imageDataPtr == null) {
            return error.InvalidInput;
        }

        const imageSize: usize = @intCast(width * height * channels);
        const imageData = try alloc.alloc(u8, imageSize);
        @memcpy(imageData, imageDataPtr[0..imageSize]);

        const seamImageData = try alloc.alloc(u32, @intCast(width * height));

        c.stbi_image_free(imageDataPtr);

        return Image{
            .width = @intCast(width),
            .height = @intCast(height),
            .channels = @intCast(channels),
            .size = imageSize,
            .data = imageData[0..imageSize],
            .stride = @intCast(width),
            .seamImageData = seamImageData,
        };
    }

    fn init(alloc: anytype, width: usize, height: usize, channels: usize, stride: usize) !Image {
        const size = stride * height * channels;
        const data = try alloc.alloc(u8, size);
        return Image{
            .width = width,
            .height = height,
            .channels = channels,
            .size = size,
            .data = data,
            .stride = stride,
        };
    }

    fn applyGrayscale(self: *Image, from: *const Image) void {
        assert(self.channels == 1);
        assert(from.channels == 3);
        assert(self.stride == from.stride);

        self.width = from.width;

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const pixelOffset = (x + self.stride * y) * from.channels;
                const r: f32 = @floatFromInt(from.data[pixelOffset + 0]);
                const g: f32 = @floatFromInt(from.data[pixelOffset + 1]);
                const b: f32 = @floatFromInt(from.data[pixelOffset + 2]);
                // https://stackoverflow.com/a/596243
                const grayscale = 0.299 * r + 0.587 * g + 0.114 * b;
                self.data[x + self.stride * y] = @intFromFloat(grayscale);
            }
        }
    }

    fn applySobelOperator(self: *Image, from: *const Image) void {
        assert(self.channels == 1);
        assert(from.channels == 1);

        self.width = from.width;

        const neighborOffsets = [_]@Vector(2, i32){ .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 0, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };
        const kernelX = [_]i32{ 1, 0, -1, 2, 0, -2, 1, 0, -1 };
        const kernelY = [_]i32{ 1, 2, 1, 0, 0, 0, -1, -2, -1 };

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const pixelOffset = x + self.stride * y;
                if (x == 0 or x == self.width - 1 or y == 0 or y == self.height - 1) {
                    // to discourage seams from being carved along the edges
                    self.data[pixelOffset] = 0xFF;
                    continue;
                }
                var gx: i32 = 0;
                var gy: i32 = 0;
                inline for (neighborOffsets, kernelX, kernelY) |neigh, kX, kY| {
                    const neighX: usize = @intCast(@as(i32, @intCast(x)) + neigh[0]);
                    const neighY: usize = @intCast(@as(i32, @intCast(y)) + neigh[1]);
                    gx += from.data[neighX + self.stride * neighY] * kX;
                    gy += from.data[neighX + self.stride * neighY] * kY;
                }
                const g: u32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(gx * gx + gy * gy))));
                self.data[pixelOffset] = @truncate(g);
            }
        }
    }

    fn applySeamCarve(self: *Image, imageEnergy: Image) void {
        assert(self.channels == 3);
        assert(imageEnergy.channels == 1);
        assert(self.seamImageData != null);

        const seamImageData = self.seamImageData.?;

        // dynamic programming to find "path of least resistance"
        // https://en.wikipedia.org/wiki/Seam_carving
        var maxEnergy: u32 = 0;
        for (0..imageEnergy.height) |y| {
            for (0..imageEnergy.width) |x| {
                const offset = x + imageEnergy.stride * y;
                if (y == 0) {
                    seamImageData[offset] = imageEnergy.data[offset];
                    continue;
                }
                var minEnergy = seamImageData[x + imageEnergy.stride * (y - 1)];
                if (x != 0) {
                    minEnergy = @min(minEnergy, seamImageData[
                        (x - 1) + imageEnergy.stride * (y - 1)
                    ]);
                }
                if (x != imageEnergy.width - 1) {
                    minEnergy = @min(minEnergy, seamImageData[
                        (x + 1) + imageEnergy.stride * (y - 1)
                    ]);
                }
                const energy = imageEnergy.data[offset] + minEnergy;
                maxEnergy = @max(maxEnergy, energy);
                seamImageData[offset] = energy;
            }
        }

        // normalize values
        for (0..imageEnergy.size) |i| {
            const energy: f32 = @floatFromInt(seamImageData[i]);
            seamImageData[i] = @intFromFloat(energy / @as(f32, @floatFromInt(maxEnergy)) * 255.0);
        }

        // find the start of the seam
        var minX: usize = 0;
        var minEnergy: u8 = std.math.maxInt(u8);
        for (0..imageEnergy.width) |x| {
            const energy: u8 = @truncate(seamImageData[x + imageEnergy.stride * (imageEnergy.height - 1)]);
            if (energy < minEnergy) {
                minEnergy = energy;
                minX = x;
            }
        }

        const lastRowOffset = (minX + imageEnergy.stride * (self.height - 1)) * self.channels;
        if (lastRowOffset == self.data.len) assert(false);
        std.mem.copyForwards(u8, self.data[lastRowOffset..], self.data[(lastRowOffset + self.channels)..]);

        // carve out the seam tracing the "path of least resistance"
        var y: usize = imageEnergy.height - 2;
        while (y > 0) : (y -= 1) {
            const prevMinX = minX;
            minEnergy = @truncate(seamImageData[prevMinX + imageEnergy.stride * y]);
            if (prevMinX != 0) {
                const energy: u8 = @truncate(seamImageData[(prevMinX - 1) + imageEnergy.stride * y]);
                if (energy < minEnergy) {
                    minEnergy = energy;
                    minX = prevMinX - 1;
                }
            }
            if (prevMinX != imageEnergy.width - 1) {
                const energy: u8 = @truncate(seamImageData[(prevMinX + 1) + imageEnergy.stride * y]);
                if (energy < minEnergy) {
                    minEnergy = energy;
                    minX = prevMinX + 1;
                }
            }

            const offset = (minX + imageEnergy.stride * y) * self.channels;
            const lineEndOffset = (imageEnergy.stride + imageEnergy.stride * y) * self.channels;
            std.mem.copyForwards(u8, self.data[offset..], self.data[(offset + self.channels)..(lineEndOffset)]);
        }
        self.width -= 1;
    }

    fn deinit(self: *const Image, alloc: anytype) void {
        alloc.free(self.data);
        if (self.seamImageData != null) {
            alloc.free(self.seamImageData.?);
        }
    }
};

fn textureImage(image: Image) !void {
    switch (image.channels) {
        1 => c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_LUMINANCE, @intCast(image.stride), @intCast(image.height), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, image.data.ptr),
        3 => c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGB, @intCast(image.stride), @intCast(image.height), 0, c.GL_RGB, c.GL_UNSIGNED_BYTE, image.data.ptr),
        4 => c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, @intCast(image.stride), @intCast(image.height), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, image.data.ptr),
        else => {
            std.log.err("Unsupported number of channels: {d}\n", .{image.channels});
            return error.InvalidInput;
        },
    }
}

fn createImageTexture(image: Image) !c.GLuint {
    var texture: c.GLuint = undefined;
    c.glGenTextures(1, &texture);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);

    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    try textureImage(image);

    return texture;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var image: Image = try Image.initImageFromFile(alloc, "Broadway_tower_edit.jpg");
    defer image.deinit(alloc);

    var grayscaleImage: Image = try Image.init(alloc, image.width, image.height, 1, image.stride);
    defer grayscaleImage.deinit(alloc);

    var sobelImage = try Image.init(alloc, image.width, image.height, 1, image.stride);
    defer sobelImage.deinit(alloc);

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

    const texture = try createImageTexture(image);
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

        while (fb_width < image.width) {
            grayscaleImage.applyGrayscale(&image);
            sobelImage.applySobelOperator(&grayscaleImage);
            image.applySeamCarve(sobelImage);
        }

        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        try textureImage(image);

        c.glMatrixMode(c.GL_PROJECTION);
        c.glLoadIdentity();
        c.glOrtho(0, fb_width_f, fb_height_f, 0, -1, 1);

        c.glMatrixMode(c.GL_MODELVIEW);
        c.glLoadIdentity();

        const imageWidth: c.GLfloat = @floatFromInt(image.width);
        const imageStride: c.GLfloat = @floatFromInt(image.stride);
        const textureWidth: c.GLfloat = imageWidth / imageStride;
        c.glBegin(c.GL_QUADS);
        c.glTexCoord2f(0.0, 0.0);
        c.glVertex2f(0.0, 0.0);
        c.glTexCoord2f(textureWidth, 0.0);
        c.glVertex2f(fb_width_f, 0.0);
        c.glTexCoord2f(textureWidth, 1.0);
        c.glVertex2f(fb_width_f, fb_height_f);
        c.glTexCoord2f(0.0, 1.0);
        c.glVertex2f(0.0, fb_height_f);
        c.glEnd();

        c.glfwSwapBuffers(window);
        c.glfwPollEvents();
    }

    std.debug.print("Goodbye, world!\n", .{});
}
