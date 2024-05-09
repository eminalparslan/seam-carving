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

    fn imageFromFile(alloc: anytype, path: [*c]const u8) !Image {
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

        c.stbi_image_free(imageDataPtr);

        return Image{
            .width = @intCast(width),
            .height = @intCast(height),
            .channels = @intCast(channels),
            .size = imageSize,
            .data = imageData[0..imageSize],
        };
    }

    fn applyGrayscale(self: *const Image, alloc: anytype) !Image {
        assert(self.channels == 3);

        const grayscaleImageSize = self.size / self.channels;
        const grayscaleImageData = try alloc.alloc(u8, grayscaleImageSize);

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const pixelOffset = (x + self.width * y) * self.channels;
                const r: f32 = @floatFromInt(self.data[pixelOffset + 0]);
                const g: f32 = @floatFromInt(self.data[pixelOffset + 1]);
                const b: f32 = @floatFromInt(self.data[pixelOffset + 2]);
                // https://stackoverflow.com/a/596243
                const grayscale = 0.299 * r + 0.587 * g + 0.114 * b;
                grayscaleImageData[x + self.width * y] = @intFromFloat(grayscale);
            }
        }

        return Image{
            .width = self.width,
            .height = self.height,
            .channels = 1,
            .size = grayscaleImageSize,
            .data = grayscaleImageData,
        };
    }

    fn applySobelOperator(self: *const Image, alloc: anytype) !Image {
        assert(self.channels == 1);

        const sobelImageData = try alloc.alloc(u8, self.size);

        // defined the Sobel operator kernels
        const neighborOffsets = [_]@Vector(2, i32){ .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 0, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };
        const kernelX = [_]i32{ 1, 0, -1, 2, 0, -2, 1, 0, -1 };
        const kernelY = [_]i32{ 1, 2, 1, 0, 0, 0, -1, -2, -1 };

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const offset = x + self.width * y;
                if (x == 0 or x == self.width - 1 or y == 0 or y == self.height - 1) {
                    sobelImageData[offset] = 0;
                    continue;
                }
                var gx: i32 = 0;
                var gy: i32 = 0;
                const xi: i32 = @intCast(x);
                const yi: i32 = @intCast(y);
                inline for (neighborOffsets, kernelX, kernelY) |neigh, kX, kY| {
                    const neighX: usize = @intCast(xi + neigh[0]);
                    const neighY: usize = @intCast(yi + neigh[1]);
                    gx += self.data[neighX + self.width * neighY] * kX;
                    gy += self.data[neighX + self.width * neighY] * kY;
                }
                const g_: f32 = @floatFromInt(gx * gx + gy * gy);
                const g: u32 = @intFromFloat(@sqrt(g_));
                // FIXME
                if (g > 255) {
                    sobelImageData[offset] = 255;
                } else {
                    sobelImageData[offset] = @intCast(g);
                }
            }
        }

        return Image{
            .width = self.width,
            .height = self.height,
            .channels = self.channels,
            .size = self.size,
            .data = sobelImageData,
        };
    }

    fn applySeamCarve(self: *const Image, alloc: anytype, imageEnergy: Image) !Image {
        assert(self.channels == 3);
        assert(imageEnergy.channels == 1);

        const carvedImageData = try alloc.alloc(u8, self.size);
        @memcpy(carvedImageData, self.data);

        const seamImageDataUnnormalized = try alloc.alloc(u32, imageEnergy.size);
        defer alloc.free(seamImageDataUnnormalized);

        const seamImageData = try alloc.alloc(u8, imageEnergy.size);
        defer alloc.free(seamImageData);

        // dynamic programming to find "path of least resistance"
        // https://en.wikipedia.org/wiki/Seam_carving
        var maxEnergy: u32 = 0;
        for (0..imageEnergy.height) |y| {
            for (0..imageEnergy.width) |x| {
                const offset = x + imageEnergy.width * y;
                if (y == 0) {
                    seamImageDataUnnormalized[offset] = imageEnergy.data[offset];
                    continue;
                }
                var minEnergy = seamImageDataUnnormalized[x + imageEnergy.width * (y - 1)];
                if (x != 0) {
                    minEnergy = @min(minEnergy, seamImageDataUnnormalized[
                        (x - 1) + imageEnergy.width * (y - 1)
                    ]);
                }
                if (x != imageEnergy.width - 1) {
                    minEnergy = @min(minEnergy, seamImageDataUnnormalized[
                        (x + 1) + imageEnergy.width * (y - 1)
                    ]);
                }
                const energy = imageEnergy.data[offset] + minEnergy;
                maxEnergy = @max(maxEnergy, energy);
                seamImageDataUnnormalized[offset] = energy;
            }
        }

        // normalize values
        for (0..imageEnergy.size) |i| {
            const energy: f32 = @floatFromInt(seamImageDataUnnormalized[i]);
            const maxEnergy_: f32 = @floatFromInt(maxEnergy);
            seamImageData[i] = @intFromFloat(energy / maxEnergy_ * 255.0);
        }

        // find the start of the seam
        var minX: usize = 0;
        var minEnergy = seamImageData[minX + imageEnergy.width * (imageEnergy.height - 1)];
        for (1..imageEnergy.width) |x| {
            const energy = seamImageData[x + imageEnergy.width * (imageEnergy.height - 1)];
            if (energy < minEnergy) {
                minEnergy = energy;
                minX = x;
            }
        }

        const lastRowOffset = (minX + imageEnergy.width * (self.height - 1)) * self.channels;
        carvedImageData[lastRowOffset + 0] = 0xFF;
        carvedImageData[lastRowOffset + 1] = 0x00;
        carvedImageData[lastRowOffset + 2] = 0x00;

        // carve out the seam tracing the "path of least resistance"
        var y: usize = imageEnergy.height - 2;
        while (y > 0) : (y -= 1) {
            const prevMinX = minX;
            minEnergy = seamImageData[prevMinX + imageEnergy.width * y];
            if (prevMinX != 0) {
                const energy = seamImageData[(prevMinX - 1) + imageEnergy.width * y];
                if (energy < minEnergy) {
                    minEnergy = energy;
                    minX = prevMinX - 1;
                }
            }
            if (prevMinX != imageEnergy.width - 1) {
                const energy = seamImageData[(prevMinX + 1) + imageEnergy.width * y];
                if (energy < minEnergy) {
                    minEnergy = energy;
                    minX = prevMinX + 1;
                }
            }

            const offset = (minX + imageEnergy.width * y) * self.channels;
            carvedImageData[offset + 0] = 0xFF;
            carvedImageData[offset + 1] = 0x00;
            carvedImageData[offset + 2] = 0x00;
        }

        return Image{
            .width = self.width,
            .height = self.height,
            .channels = self.channels,
            .size = self.size,
            .data = carvedImageData,
        };
    }

    fn deinit(self: *const Image, alloc: anytype) void {
        alloc.free(self.data);
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

    switch (image.channels) {
        1 => c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_LUMINANCE, @intCast(image.width), @intCast(image.height), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, image.data.ptr),
        3 => c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGB, @intCast(image.width), @intCast(image.height), 0, c.GL_RGB, c.GL_UNSIGNED_BYTE, image.data.ptr),
        4 => c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, @intCast(image.width), @intCast(image.height), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, image.data.ptr),
        else => {
            std.log.err("Unsupported number of channels: {d}\n", .{image.channels});
            return error.InvalidInput;
        },
    }

    c.glGenerateMipmap(c.GL_TEXTURE_2D);

    return texture;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const image: Image = try Image.imageFromFile(alloc, "Broadway_tower_edit.jpg");
    defer image.deinit(alloc);

    const grayscaleImage: Image = try image.applyGrayscale(alloc);
    defer grayscaleImage.deinit(alloc);

    const sobelImage = try grayscaleImage.applySobelOperator(alloc);
    defer sobelImage.deinit(alloc);

    const seamCarveImage = try image.applySeamCarve(alloc, sobelImage);
    defer seamCarveImage.deinit(alloc);

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

    const texture = try imageToTexture(seamCarveImage);
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
