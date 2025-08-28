//! Dotenv: Loading, parsing, and setting environment variables from a .env file (or any file) with ease.
//!
//! Example:
//!
//! ```zig
//! pub const EnvKeys = enum {
//!   OPENAI_API_KEY,
//!   AWS_ACCESS_KEY_ID,
//! };
//!
//! const env = dotenv.Env(EnvKeys).init(allocator, false);
//! defer env.deinit();
//!
//! try env.load(.{ filename = ".env.local" }); // or try env.load(.{}) -> to load .env instead
//!
//! const openai_key = env.key(.OPENAI_API_KEY);
//! std.debug.print("OPENAI_API_KEY={s}\n", .{openai_key});
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const testing = std.testing;
const fs = std.fs;
const Io = std.Io;

const log = std.log.scoped(.dotenv);

const dotenv = @This();

const LoadOptions = struct {
    /// Defaults to `.env`
    filename: ?[]const u8 = null,

    /// Set variables in the current process environment, if false, only the internal library env hashmap is populated
    set_envs_in_process: bool = false,
};

pub fn Env(comptime EnvKey: type) type {
    comptime {
        if (@typeInfo(EnvKey) != .@"enum") {
            @compileError("EnvKey must be an enum:  enum {...}");
        }
    }

    return struct {
        /// Path to the environment file, defaults to ".env"
        filename: []const u8,

        /// Storage for environment variables using a string hash map
        /// Allows for optional string values (null represents unset)
        items: std.process.EnvMap,

        included_process_env: bool,

        /// Memory allocator used for managing string allocations
        allocator: Allocator,

        const Self = @This();

        /// Initializes a new empty Env struct instance
        ///
        /// If `includeCurrentProcessEnvs = true`, the current process' environment variables will be included in the Env struct
        ///
        /// Caller must deinit
        pub fn init(allocator: Allocator, include_current_process_envs: bool) Self {
            return Self{
                .filename = ".env",
                .allocator = allocator,
                .items = if (include_current_process_envs)
                    std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator)
                else
                    std.process.EnvMap.init(allocator),
                .included_process_env = include_current_process_envs,
            };
        }

        /// Deallocates all memory associated with the Env struct
        ///
        /// Frees all dynamically allocated keys and values,
        /// and deinitializes the underlying hash map
        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }

        /// Loads environment variables from a file
        ///
        /// Supports variable interpolation in values using the format `${OTHER_VAR}`
        /// Interpolated variables are resolved from previously loaded values or the current process environment
        ///
        pub fn load(self: *Self, options: LoadOptions) !void {
            self.filename = if (options.filename) |fln| fln else self.filename;

            const envFile = try std.fs.cwd().openFile(self.filename, .{ .mode = .read_only });
            defer envFile.close();

            const fstat = try envFile.stat();
            const fsize = fstat.size;

            const content = try envFile.readToEndAlloc(self.allocator, fsize);
            defer self.allocator.free(content);

            try self.parse(content);

            if (options.set_envs_in_process) {
                var it = self.items.iterator();
                while (it.next()) |entry| {
                    try self.setProcessEnv(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }

        /// Loads the current process environment variables into the Env struct.
        ///
        /// Populates the internal map with all environment variables from the current process
        ///
        pub fn loadCurrentProcessEnvs(self: *Self) !void {
            var env_map = try std.process.getEnvMap(self.allocator);
            defer env_map.deinit();
            var it = env_map.iterator();
            while (it.next()) |e| {
                try self.items.put(e.key_ptr.*, e.value_ptr.*);
            }
        }

        /// Retrieves the value of a specific environment variable by name
        ///
        /// Example:
        /// ```zig
        ///  const openai_key = env.get("OPENAI_API_KEY");
        ///  std.debug.print("OPENAI_API_KEY={s}\n", .{openai_key});
        /// ```
        pub fn get(self: *Self, k: []const u8) []const u8 {
            return self.items.get(k).?;
        }

        /// Retrieves the value of a specific environment variable from the provided enum keys
        ///
        /// Example:
        /// ```zig
        /// const openai_key = env.key(.OPENAI_API_KEY);
        /// std.debug.print("OPENAI_API_KEY={s}\n", .{openai_key});
        /// ```
        pub fn key(self: *Self, k: EnvKey) []const u8 {
            return self.items.get(@tagName(k)).?;
        }

        /// Splits the `content` into lines and extracts key-value pairs
        /// Supports comments (lines starting with #) and trims whitespace
        ///
        /// Additionally, supports variable interpolation in values using the format `${OTHER_VAR}`
        /// Interpolated variables are resolved from other parsed values or the current process environment
        /// (if not already included during initialization)
        ///
        pub fn parse(self: *Self, content: []u8) !void {
            var internal_temp_map = std.process.EnvMap.init(self.allocator);
            defer internal_temp_map.deinit();

            var found_to_interpolate: bool = false;

            var line = std.mem.splitScalar(u8, content, '\n');
            while (line.next()) |l| {
                if (l.len == 0 or l[0] == '#') continue;

                var pair = std.mem.splitScalar(u8, l, '=');
                const k = std.mem.trim(u8, pair.first(), " \t");

                if (pair.next()) |value| {
                    var value_trimmed = std.mem.trim(u8, value, " \t");
                    if (value_trimmed.len >= 2) {
                        if (value_trimmed[0] == '"' and value_trimmed[value_trimmed.len - 1] == '"') {
                            value_trimmed = value_trimmed[1 .. value_trimmed.len - 1];
                        } else if (value_trimmed[0] == '\'' and value_trimmed[value_trimmed.len - 1] == '\'') {
                            value_trimmed = value_trimmed[1 .. value_trimmed.len - 1];
                        }
                        if (std.mem.startsWith(u8, value_trimmed, "$")) found_to_interpolate = true;
                    }

                    try self.items.put(k, value_trimmed);
                    try internal_temp_map.put(k, value_trimmed);
                }
            }

            // resolve ${other var}
            if (found_to_interpolate) {
                if (!self.included_process_env) {
                    var env_map = try std.process.getEnvMap(self.allocator);
                    defer env_map.deinit();

                    var it = env_map.iterator();
                    while (it.next()) |e| {
                        try internal_temp_map.put(e.key_ptr.*, e.value_ptr.*);
                    }
                }

                var it = self.items.iterator();
                while (it.next()) |e| {
                    try internal_temp_map.put(e.key_ptr.*, e.value_ptr.*);
                }

                it = internal_temp_map.iterator();

                while (it.next()) |e| {
                    const k = e.key_ptr.*;
                    const v = e.value_ptr.*;

                    if (std.mem.startsWith(u8, v, "$")) {
                        const var_name = if (std.mem.startsWith(u8, v[1..], "{") and std.mem.endsWith(u8, v, "}")) v[2 .. v.len - 1] else v[1..];

                        const resolved_value = if (var_name.len > 0) internal_temp_map.get(var_name) orelse "" else "";

                        try self.items.put(k, resolved_value);
                    }
                }
            }
        }

        /// Sets or Unsets an environment variable in the current process
        ///
        pub fn setProcessEnv(self: *Self, k: []const u8, v: ?[]const u8) !void {
            const builtin = @import("builtin");
            const os = builtin.os.tag;

            // Import C standard library for setenv/unsetenv
            const c = @cImport({
                @cInclude("stdlib.h");
                if (os == .windows) {
                    @cInclude("windows.h");
                }
            });

            const key_c = try self.allocator.dupeZ(u8, k);
            defer self.allocator.free(key_c);

            if (v) |val| {
                // Setting a value
                const value_c = try self.allocator.dupeZ(u8, val);
                defer self.allocator.free(value_c);

                switch (os) {
                    .windows => {
                        if (c.SetEnvironmentVariableA(key_c, value_c) == 0) {
                            return error.SetEnvFailed;
                        }
                    },
                    else => { // POSIX systems
                        if (c.setenv(key_c, value_c, 1) != 0) {
                            return error.SetEnvFailed;
                        }
                    },
                }

                // Use setenv to set the environment variable
            } else {
                switch (builtin.os.tag) {
                    .windows => {
                        if (c.SetEnvironmentVariableA(key_c, null) == 0) {
                            return error.UnsetEnvFailed;
                        }
                    },
                    else => { // POSIX systems
                        if (c.unsetenv(key_c) != 0) {
                            return error.UnsetEnvFailed;
                        }
                    },
                }
            }
        }

        /// Writes all environment variables to a provided writer
        ///
        /// Outputs each key-value pair in the format "KEY=VALUE\n"
        ///
        /// Example to write to a random file:
        /// ```zig
        ///  const file = std.fs.cwd().openFile("test.txt", .{ .mode = .read_write }) catch |err| switch (err) {
        ///  error.FileNotFound => try std.fs.cwd().createFile("test.txt", .{}),
        ///  else => return err,
        ///  };
        ///  defer file.close();
        ///
        ///  var writer = file.writerStreaming(&.{});
        ///  try env.writeAllEnvPairs(&writer.interface, true);
        /// ```
        ///
        pub fn writeAllEnvPairs(self: *Self, writer: *Io.Writer, include_system_vars: bool) !void {
            if (include_system_vars and !self.included_process_env) try self.loadCurrentProcessEnvs();

            if (self.items.count() == 0) {
                try writer.writeAll("No environments variables set\n");
                return;
            }

            var it = self.items.iterator();
            while (it.next()) |entry| {
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("=");
                try writer.writeAll(entry.value_ptr.*);
                try writer.writeAll("\n");
            }
        }

        /// Creates file if if doesn't already exist
        ///
        /// If filename is null, writes to the loaded filename or defaults to ".env"
        ///
        pub fn writeEnvPairToFile(self: *Self, k: []const u8, v: []const u8, filename: ?[]const u8) !void {
            const fname = if (filename) |f| f else self.filename;

            const file = std.fs.cwd().openFile(fname, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => try std.fs.cwd().createFile(fname, .{}),
                else => return err,
            };
            defer file.close();

            const content = try std.fmt.allocPrint(self.allocator, "{s}={s}\n", .{ k, v });
            defer self.allocator.free(content);

            const end_pos = try file.getEndPos();
            if (end_pos > 0) {
                var buf: [1]u8 = undefined;
                _ = try file.pread(&buf, end_pos - 1);
                try file.seekTo(end_pos);
                if (buf[0] != '\n') {
                    try file.writeAll("\n");
                }
            }

            try file.writeAll(content);
        }
    };
}

// Define test environment keys
const EnvKeys = enum(u8) {
    TEST_KEY1,
    TEST_KEY2,
    TEST_EMPTY_KEY,
    TEST_NUMERIC_VALUE,
};

test "Env initialization and deinitialization" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    try testing.expectEqual(env.items.count(), 0);
    try testing.expectEqualStrings(env.filename, ".env");
}

test "Env custom filename" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    // Test setting a custom filename
    env.load(.{ .filename = ".env.test", .set_envs_in_process = true }) catch {};
    try testing.expectEqualStrings(env.filename, ".env.test");
}

test "Parse environment variables" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    // Test parsing content
    const content =
        \\TEST_KEY1="value1"
        \\# Comment line
        \\TEST_KEY2='value2'
        \\TEST_EMPTY_KEY=''
        \\TEST_NUMERIC_VALUE=123
    ;

    try env.parse(@constCast(content));

    try testing.expectEqualStrings(env.get("TEST_KEY1"), "value1");
    try testing.expectEqualStrings(env.get("TEST_KEY2"), "value2");
    try testing.expectEqualStrings(env.get("TEST_EMPTY_KEY"), "");
    try testing.expectEqualStrings(env.get("TEST_NUMERIC_VALUE"), "123");
    try testing.expectEqual(env.items.count(), 4);
}

test "Get environment variables by string key" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    const content =
        \\TEST_KEY1=value1
        \\TEST_KEY2=value2
    ;

    try env.parse(@constCast(content));

    try testing.expectEqualStrings(env.get("TEST_KEY1"), "value1");
    try testing.expectEqualStrings(env.get("TEST_KEY2"), "value2");
}

test "Get environment variables by enum key" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, true);
    defer env.deinit();

    const content =
        \\TEST_KEY1=value1
        \\TEST_KEY2=value2
        \\TEST_NUMERIC_VALUE=123
    ;

    try env.parse(@constCast(content));

    try testing.expectEqualStrings(env.key(.TEST_KEY1), "value1");
    try testing.expectEqualStrings(env.key(.TEST_KEY2), "value2");
    try testing.expectEqualStrings(env.key(.TEST_NUMERIC_VALUE), "123");
}

// Helper function to create a test .env file
fn createTestEnvFile(filename: []const u8, content: []const u8) !void {
    const file = try fs.cwd().createFile(filename, .{});
    defer file.close();

    try file.writeAll(content);
}

// Helper function to delete a test .env file
fn deleteTestEnvFile(filename: []const u8) void {
    fs.cwd().deleteFile(filename) catch {};
}

test "Load environment from file" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    // Create test .env file
    const filename = ".env.test";
    const content =
        \\TEST_KEY1=filevalue1
        \\TEST_KEY2=filevalue2
    ;

    try createTestEnvFile(filename, content);
    defer deleteTestEnvFile(filename);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    try env.load(.{ .filename = filename, .set_envs_in_process = true });

    try testing.expectEqualStrings(env.get("TEST_KEY1"), "filevalue1");
    try testing.expectEqualStrings(env.get("TEST_KEY2"), "filevalue2");
}

test "Load environment with trimmed values" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    // Create test .env file with whitespace
    const filename = ".env.trimtest";
    const content =
        \\TEST_KEY1 = value_with_spaces
        \\  TEST_KEY2=tabbed_value
        \\TEST_EMPTY_KEY = 
    ;

    try createTestEnvFile(filename, content);
    defer deleteTestEnvFile(filename);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    try env.load(.{ .filename = filename, .set_envs_in_process = true });

    try testing.expectEqualStrings(env.get("TEST_KEY1"), "value_with_spaces");
    try testing.expectEqualStrings(env.get("TEST_KEY2"), "tabbed_value");
    try testing.expectEqualStrings(env.get("TEST_EMPTY_KEY"), "");
}

test "Write environment variables" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, true);
    defer env.deinit();

    const content =
        \\TEST_KEY1=value1
        \\TEST_KEY2=value2
    ;

    try env.parse(@constCast(content));

    // Test writing to a buffer
    var buffer = Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    try env.writeAllEnvPairs(&buffer.writer, false);

    // Check if the output contains our environment variables
    const output = buffer.written();
    try testing.expect(std.mem.indexOf(u8, output, "TEST_KEY1=value1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "TEST_KEY2=value2") != null);
}

test "Set process environment variables" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    // Set a test environment variable
    try env.setProcessEnv("TEST_ENV_VAR", "test_value");

    // Get environment variable to verify it was set
    const value = try std.process.getEnvVarOwned(allocator, "TEST_ENV_VAR");
    defer allocator.free(value);

    try testing.expectEqualStrings(value, "test_value");

    // Unset the environment variable
    try env.setProcessEnv("TEST_ENV_VAR", null);

    // Verify it was unset (should throw error)
    try testing.expectError(error.EnvironmentVariableNotFound, std.process.getEnvVarOwned(allocator, "TEST_ENV_VAR"));
}

test "Non-existent environment file" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    // Should not throw error for non-existent file
    env.load(.{ .filename = "non_existent_file.env", .set_envs_in_process = true }) catch {};

    try testing.expectEqual(env.items.count(), 0);
}

test "Handle comments and empty lines" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    const content =
        \\# This is a comment
        \\
        \\TEST_KEY1=value1
        \\# Another comment
        \\TEST_KEY2=value2
        \\
    ;

    try env.parse(@constCast(content));

    try testing.expectEqual(env.items.count(), 2);
    try testing.expectEqualStrings(env.get("TEST_KEY1"), "value1");
    try testing.expectEqualStrings(env.get("TEST_KEY2"), "value2");
}

test "Environment file with and without .env extension" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    // Test with .env extension
    {
        const filename = ".env.regular";
        const content = "TEST_KEY1=regular";

        try createTestEnvFile(filename, content);
        defer deleteTestEnvFile(filename);

        var env = TestEnv.init(allocator, false);
        defer env.deinit();
        try env.load(.{ .filename = filename });

        try testing.expectEqualStrings(env.get("TEST_KEY1"), "regular");
    }

    // Test without .env extension
    {
        const filename = "envfile";
        const content = "TEST_KEY1=noextension";

        try createTestEnvFile(filename, content);
        defer deleteTestEnvFile(filename);

        var env = TestEnv.init(allocator, true);
        defer env.deinit();

        try env.load(.{ .filename = filename, .set_envs_in_process = true });

        try testing.expectEqualStrings(env.get("TEST_KEY1"), "noextension");
    }
}

// Integration test with all features
test "Integration test" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    // Create test file
    const filename = ".env.integration";
    const content =
        \\# Test .env file
        \\TEST_KEY1=integration_value1
        \\TEST_KEY2 = integration_value2
        \\TEST_EMPTY_KEY=
        \\TEST_NUMERIC_VALUE=42
        \\
    ;

    try createTestEnvFile(filename, content);
    defer deleteTestEnvFile(filename);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    // Load from file
    try env.load(.{ .filename = filename, .set_envs_in_process = true });

    // Test string key access
    try testing.expectEqualStrings(env.get("TEST_KEY1"), "integration_value1");
    try testing.expectEqualStrings(env.get("TEST_KEY2"), "integration_value2");

    // Test enum key access
    try testing.expectEqualStrings(env.key(.TEST_KEY1), "integration_value1");
    try testing.expectEqualStrings(env.key(.TEST_NUMERIC_VALUE), "42");

    // Test process env setting
    try env.setProcessEnv("TEST_PROCESS_VAR", "process_value");
    const proc_value = try std.process.getEnvVarOwned(allocator, "TEST_PROCESS_VAR");
    defer allocator.free(proc_value);
    try testing.expectEqualStrings(proc_value, "process_value");

    // Test writing
    var buffer = Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    try env.writeAllEnvPairs(&buffer.writer, false);

    const output = buffer.written();
    try testing.expect(std.mem.indexOf(u8, output, "TEST_KEY1=integration_value1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "TEST_KEY2=integration_value2") != null);
}

test "writeEnvPairToFile appends key=value to a file" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator, false);
    defer env.deinit();

    const test_filename = "test.env";

    // clear file content first - for testing purposes
    {
        const file = try std.fs.cwd().createFile(test_filename, .{ .truncate = true });
        file.close();
    }

    try env.writeEnvPairToFile("TEST_KEY", "test_value", test_filename);

    // Read back contents
    const file = try fs.cwd().openFile(test_filename, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    _ = try file.readAll(content);

    try testing.expectEqualStrings("TEST_KEY=test_value\n", content);

    // Clean up
    try fs.cwd().deleteFile(test_filename);
}
