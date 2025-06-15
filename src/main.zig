//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const Chunk = struct {
    chunk_type: []const u8,
    chunk_length: u32,
    chunk_data: []const u8,

    pub fn init(chunk_type: []const u8, chunk_length: u32, chunk_data: []const u8) Chunk {
        return Chunk{ .chunk_data = chunk_data, .chunk_length = chunk_length, .chunk_type = chunk_type };
    }
};

const Arguments = struct {
    path: []const u8,

    pub const description = "A simple PNG reader written in Zig";
    pub const descriptions = .{
        .path = "Path to the PNG file to read",
    };
};

const Png = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const arguments = aflags.parse(args, "Png Viewer", Arguments, .{}) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        return;
    };

    // Check if the given path is absolute
    // If not, convert it to an absolute path
    const path = try std.fs.cwd().realpathAlloc(allocator, arguments.path);
    defer allocator.free(path);

    const file = try fs.cwd().openFile(path, .{ .mode = flags.read_only });
    const stat = try file.stat();
    std.debug.print("File Size: {}\n", .{stat.size});
    defer file.close();

    var buff = try allocator.alloc(u8, stat.size);
    defer allocator.free(buff);
    for (0.., buff) |index, _| {
        buff[index] = 0;
    }
    var length: u32 = 0;
    var prev_length: u32 = 0;

    // Read the entire file into the buffer
    const readSize = try file.read(buff[0..]);
    if (readSize == 0) {
        std.debug.print("Unable to read the file", .{});
        return;
    }

    // Check if the given file is valid png by checking png signature
    const png_header = "\x89PNG\r\n\x1a\n";
    var file_header: [8]u8 = undefined;
    prev_length = length;
    length = length + 8;
    const bytes_written = try std.fmt.bufPrint(&file_header, "{s}", .{buff[prev_length..length]});
    if (bytes_written.len == 0) {
        std.debug.print("Unable to read the file header", .{});
        return;
    }

    if (!std.mem.eql(u8, png_header, file_header[0..file_header.len])) {
        std.debug.print("Not a png file", .{});
        return;
    }

    var chunks = std.ArrayList(Chunk).init(allocator);
    defer chunks.deinit();
    const end = "IEND";
    while (true) {
        const chunk = read_chunk(buff[0..buff.len], &prev_length, &length);
        try chunks.append(chunk);
        if (std.mem.eql(u8, chunk.chunk_type, end)) {
            break;
        }
    }

    const IHDR_chunk = chunks.items[0];
    const png = Png{
        .width = std.mem.readInt(u32, IHDR_chunk.chunk_data[0..4], endian.big),
        .height = std.mem.readInt(u32, IHDR_chunk.chunk_data[4..8], endian.big),
        .bit_depth = IHDR_chunk.chunk_data[8],
        .color_type = IHDR_chunk.chunk_data[9],
        .compression_method = IHDR_chunk.chunk_data[10],
        .filter_method = IHDR_chunk.chunk_data[11],
        .interlace_method = IHDR_chunk.chunk_data[12],
    };
    std.debug.print("PNG Image Info: {any}\n", .{png});
    const bytes_per_pixel: u8 = switch (png.color_type) {
        0 => 1, // Grayscale
        2 => 3, // RGB
        3 => 1, // Palette
        4 => 2, // Grayscale with alpha
        6 => 4, // RGBA
        else => @panic("Unsupported color type"),
    };
    const stride = @as(usize, @intCast(png.width)) * @as(usize, @intCast(bytes_per_pixel));

    const combined_data = try combine_IDAT_chunks(chunks.items, allocator);
    defer allocator.free(combined_data);

    // Decompress the combined IDAT data
    const decompressed_data = try decompress_idat_data(combined_data, allocator, png.width, png.height, bytes_per_pixel);
    defer allocator.free(decompressed_data);

    std.debug.print("Decompressed Data Length: {}\n", .{decompressed_data.len});

    // Reconstruct the image data
    const reconstructed_data = try reconstruct_image_data(allocator, decompressed_data[0..], bytes_per_pixel, png.width, png.height, stride);
    defer allocator.free(reconstructed_data);
    // std.debug.print("Reconstructed Data Length: {any}\n", .{reconstructed_data});
    try create_window(@as(i32, @intCast(png.width)), @as(i32, @intCast(png.height)), reconstructed_data, bytes_per_pixel);
}

fn read_chunk(buff: []u8, prev_length: *u32, length: *u32) Chunk {
    // Read the chunk length
    prev_length.* = length.*;
    length.* = length.* + 4;
    const chunk_length = std.mem.readInt(u32, buff[prev_length.*..length.*][0..4], endian.big);
    // std.debug.print("Chunk Length {any}\n", .{chunk_length});

    prev_length.* = length.*;
    length.* = length.* + 4;
    var chunk_name_buffer: [10]u8 = undefined;
    @memset(&chunk_name_buffer, 0);
    const chunk_type = buff[prev_length.*..length.*];
    // std.debug.print("Chunk type {s}\n", .{chunk_type});

    prev_length.* = length.*;
    length.* = length.* + chunk_length;

    const chunk_data = buff[prev_length.*..length.*];
    // std.debug.print("Chunk Data {any}\n", .{chunk_data});

    // Calculate the CRC of the chunk
    const checksum = calculate_crc(chunk_type, chunk_data);

    prev_length.* = length.*;
    length.* = length.* + 4;
    const crc = std.mem.readInt(u32, buff[prev_length.*..length.*][0..4], endian.big);

    if (checksum != crc) {
        std.debug.print("Chunk CRC mismatch: {any} != {any}\n", .{ checksum, crc });
        @panic("Chunk CRC mismatch");
    }

    return Chunk.init(chunk_type, chunk_length, chunk_data);
}

fn combine_IDAT_chunks(chunks: []const Chunk, allocator: std.mem.Allocator) ![]u8 {
    var combined_data = std.ArrayList(u8).init(allocator);
    for (chunks) |chunk| {
        if (std.mem.eql(u8, chunk.chunk_type, "IDAT")) {
            try combined_data.appendSlice(chunk.chunk_data);
        }
    }

    return combined_data.toOwnedSlice();
}

fn calculate_crc(chunk_type: []const u8, chunk_data: []const u8) u32 {
    var crc32 = std.hash.Crc32.init();
    crc32.update(chunk_type);
    crc32.update(chunk_data);
    return crc32.final();
}

fn PaethPredictor(a: usize, b: usize, c: usize) usize {
    const a_i32: i32 = @intCast(a);
    const b_i32: i32 = @intCast(b);
    const c_i32: i32 = @intCast(c);

    const p: i32 = a_i32 + b_i32 - c_i32;
    const pa: u32 = @abs(p - a_i32);
    const pb: u32 = @abs(p - b_i32);
    const pc: u32 = @abs(p - c_i32);

    if (pa <= pb and pa <= pc) {
        return a;
    } else if (pb <= pc) {
        return b;
    } else {
        return c;
    }
}

fn reconstruct_image_data(allocator: std.mem.Allocator, decompressed_data: []const u8, bytes_per_pixel: u8, width: u32, height: u32, stride: usize) ![]usize {
    // Reconstruct the image data
    var reconstructed = std.ArrayList(usize).init(allocator);
    std.debug.print("Expected total bytes: {}\n", .{width * height * bytes_per_pixel});
    std.debug.print("Decompressed data length: {}\n", .{decompressed_data.len});
    var i: u32 = 0;
    for (0..height) |row| {
        if (i >= decompressed_data.len) break;
        const filter_type = decompressed_data[i];
        i += 1;
        for (0..stride) |col| {
            if (i >= decompressed_data.len) break;
            const fil_x = decompressed_data[i];
            var recon_x: usize = undefined;
            i += 1;
            switch (filter_type) {
                0 => recon_x = fil_x, // No filter
                1 => recon_x = fil_x + recons_a(row, col, stride, bytes_per_pixel, &reconstructed), //Sub
                2 => recon_x = fil_x + recons_b(row, col, stride, &reconstructed), //Up
                3 => recon_x = fil_x + (recons_a(row, col, stride, bytes_per_pixel, &reconstructed) + recons_b(row, col, stride, &reconstructed)) / 2, //Average
                4 => recon_x = fil_x + PaethPredictor(recons_a(row, col, stride, bytes_per_pixel, &reconstructed), recons_b(row, col, stride, &reconstructed), recons_c(row, col, stride, bytes_per_pixel, &reconstructed)), // Paeth
                else => @panic("unknown filter type "),
            }
            recon_x = recon_x & 0xFF; // Ensure recon_x is within byte range
            try reconstructed.append(recon_x);
        }
    }

    return reconstructed.toOwnedSlice();
}

fn recons_a(r: usize, c: usize, stride: usize, bytes_per_pixel: u8, recon: *std.ArrayList(usize)) usize {
    if (c >= bytes_per_pixel) {
        return recon.items[r * stride + c - bytes_per_pixel];
    } else {
        return 0; // No previous pixel
    }
}

fn recons_b(r: usize, c: usize, stride: usize, recon: *std.ArrayList(usize)) usize {
    if (r > 0) {
        return recon.items[(r - 1) * stride + c];
    } else {
        return 0; // No previous row
    }
}

fn recons_c(r: usize, c: usize, stride: usize, bytes_per_pixel: u8, recon: *std.ArrayList(usize)) usize {
    if (r > 0 and c >= bytes_per_pixel) {
        return recon.items[(r - 1) * stride + c - bytes_per_pixel];
    } else {
        return 0; // No previous pixel in the same row
    }
}

fn create_window(width: i32, height: i32, reconstructed_data: []const usize, bytes_per_pixel: u8) !void {
    raylib.initWindow(width, height, "Png Viewer");
    defer raylib.closeWindow();
    raylib.setWindowState(.{
        .window_undecorated = true,
    });

    raylib.setTargetFPS(60);
    const texture = try draw_image(reconstructed_data, width, height, bytes_per_pixel);
    defer raylib.unloadTexture(texture);

    while (!raylib.windowShouldClose()) {
        raylib.beginDrawing();
        defer raylib.endDrawing();
        raylib.clearBackground(raylib.Color.white);
        raylib.drawTexture(texture, 0, 0, raylib.Color.white);
    }
}

fn draw_image(reconstructed_data: []const usize, width: i32, height: i32, bytes_per_pixel: u8) !raylib.Texture {
    const image = raylib.genImageColor(width, height, raylib.Color.blank);
    defer raylib.unloadImage(image);

    // Loop through the pixels and set the color
    var pixels = try raylib.loadImageColors(image);
    defer raylib.unloadImageColors(pixels);
    const pixel_count = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    for (0..pixel_count) |i| {
        if (i * bytes_per_pixel + 3 < reconstructed_data.len) {
            const color = raylib.Color.init(@intCast(reconstructed_data[i * bytes_per_pixel + 0]), @intCast(reconstructed_data[i * bytes_per_pixel + 1]), @intCast(reconstructed_data[i * bytes_per_pixel + 2]), if (bytes_per_pixel == 4) @intCast(reconstructed_data[i * bytes_per_pixel + 3]) else 255 // Alpha channel if present
            );
            pixels[i] = color;
            // std.debug.print("pixels: {any} i: {any}\n", .{pixels[i], i});
        } else {
            pixels[i] = raylib.Color.blank; // Fill remaining pixels with magenta color
        }
    }
    std.debug.print("Pixel Count: {any} Reconstructed: {any}\n", .{ pixel_count, reconstructed_data.len });
    const texture = try raylib.loadTextureFromImage(image);
    raylib.updateTexture(texture, pixels.ptr);
    return texture;
}

fn decompress_idat_data(combined_data: []const u8, allocator: std.mem.Allocator, width: u32, height: u32, bytes_per_pixel: u8) ![]u8 {
    std.debug.print("Starting decompression of {} bytes\n", .{combined_data.len});

    // Create a stream for the combined IDAT data
    var fbs = std.io.fixedBufferStream(combined_data);

    // Create a zlib decompressor
    var decompressor = std.compress.zlib.decompressor(fbs.reader());

    // Read all decompressed data
    const max_size: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * @as(usize, bytes_per_pixel) + @as(usize, @intCast(height)); // + height for filter bytes
    const decompressed = try decompressor.reader().readAllAlloc(allocator, max_size);
    return decompressed[0..];
}

const std = @import("std");
const fs = @import("std").fs;
const raylib = @import("raylib");
const aflags = @import("flags");
const endian = std.builtin.Endian;
const flags = fs.File.OpenMode;
const PATH = "s1.png";
