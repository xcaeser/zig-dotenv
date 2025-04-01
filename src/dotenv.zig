const std = @import("std");

const print = std.debug.print;

/// Creates a generic environment variable management struct
///
/// This function returns a type that can be used to manage environment variables.
/// It allows loading, parsing, and setting environment variables from a .env file.
///
/// @param EnvKey An enum type representing the expected environment variable keys.
///
/// @return A struct with methods for environment variable management
///
/// Example:
///
/// ```zig
/// pub const EnvKeys = enum(u8) {
///   OPENAI_API_KEY,
///   AWS_ACCESS_KEY_ID,
/// };
/// const Env = dotenv.Env(EnvKeys);
/// var env = Env.init(allocator);
/// defer env.deinit();
///
/// try env.load(".env.local"); // or try env.load(null) -> to load .env instead
///
/// const openai_key = env.key(.OPENAI_API_KEY);
/// std.debug.print("OPENAI_API_KEY={s}\n", .{openai_key});
/// ```
pub fn Env(comptime EnvKey: type) type {
    return struct {
        /// Path to the environment file, defaults to ".env"
        filename: []const u8 = ".env",

        /// Storage for environment variables using a string hash map
        /// Allows for optional string values (null represents unset)
        items: std.process.EnvMap,

        /// Memory allocator used for managing string allocations
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Initializes a new empty Env struct instance
        ///
        /// Creates an empty StringArrayHashMap for storing environment variables
        ///
        /// `@param allocator` Memory allocator for managing string allocations
        ///
        /// `@return` A new Env struct instance
        ///
        /// Caller must deinit
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .items = std.process.EnvMap.init(allocator),
                .allocator = allocator,
            };
        }

        /// Initializes a new Env struct instance with the current process environment variables
        ///
        /// `@return` A new Env struct instance
        ///
        /// Caller must deinit
        pub fn initWithProcessEnvs(allocator: std.mem.Allocator) !Self {
            return Self{
                .items = try std.process.getEnvMap(allocator),
                .allocator = allocator,
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
        /// Reads the specified file (or .env by default), parses its contents,
        /// and sets the parsed variables in the current process environment using `stdlib.h`
        ///
        /// `@param filename` Optional custom filename for the environment file
        ///
        /// `@param silent` flag to suppress error messages
        ///
        /// `@throws Error` if file cannot be read or parsed
        pub fn load(self: *Self, filename: ?[]const u8, silent: bool) !void {
            // Set filename, using default ".env" if not provided
            if (filename != null) {
                self.filename = filename.?;
            } else {
                self.filename = ".env";
            }

            // Attempt to open the environment file
            const envFile = std.fs.cwd().openFile(self.filename, .{ .mode = .read_only }) catch {
                if (!silent) {
                    print("Expected: '{s}', but no env file detected\n", .{self.filename});
                }
                return;
            };
            defer envFile.close();

            // Read entire file content (max 20KB)
            const content = try envFile.reader().readAllAlloc(self.allocator, 20 * 1024);
            defer self.allocator.free(content);

            // Parse file content into environment variables
            try self.parse(content);

            // Set parsed variables in the current process environment
            var it = self.items.iterator();
            while (it.next()) |entry| {
                try self.setProcessEnv(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        /// Retrieves the value of a specific environment variable by name
        ///
        /// `@param k` Name of the environment variable
        ///
        /// `@return String` value of the environment variable, or error message if not found
        ///
        /// Example:
        ///
        /// ```zig
        /// const openai_key = env.get("OPENAI_API_KEY");
        /// std.debug.print("OPENAI_API_KEY={s}\n", .{openai_key});
        /// ```
        pub fn get(self: *Self, k: []const u8) []const u8 {
            return self.items.get(k).?;
        }

        /// Retrieves the value of a specific environment variable from the provided enum keys
        ///
        /// Uses an enum key to safely access environment variables
        ///
        /// `@param k` Enum key representing the environment variable.
        ///
        /// `@return String` value of the environment variable, or error message if not found
        ///
        /// Example:
        ///
        /// ```zig
        /// const openai_key = env.key(.OPENAI_API_KEY);
        /// std.debug.print("OPENAI_API_KEY={s}\n", .{openai_key});
        /// ```
        pub fn key(self: *Self, k: EnvKey) []const u8 {
            return self.items.get(@tagName(k)).?;
        }

        /// Parses environment variable content from a string
        ///
        /// Splits the content into lines and extracts key-value pairs
        /// Supports comments (lines starting with #) and trims whitespace
        ///
        /// `@param content` Raw content of the environment file
        ///
        /// @throws Error during parsing or allocation
        pub fn parse(self: *Self, content: []u8) !void {
            // Split content into lines
            var line = std.mem.splitScalar(u8, content, '\n');
            while (line.next()) |l| {
                // Skip empty lines and comments
                if (l.len == 0 or l[0] == '#') continue;

                // Split line into key and value
                var pair = std.mem.splitScalar(u8, l, '=');
                const k = std.mem.trim(u8, pair.first(), " \t");

                if (pair.next()) |value| {
                    // Trim whitespace from value
                    var value_trimmed = std.mem.trim(u8, value, " \t");
                    if (value_trimmed.len >= 2) {
                        if (value_trimmed[0] == '"' and value_trimmed[value_trimmed.len - 1] == '"') {
                            value_trimmed = value_trimmed[1 .. value_trimmed.len - 1];
                        } else if (value_trimmed[0] == '\'' and value_trimmed[value_trimmed.len - 1] == '\'') {
                            value_trimmed = value_trimmed[1 .. value_trimmed.len - 1];
                        }
                    }

                    // Let EnvMap handle the memory management by using put
                    try self.items.put(k, value_trimmed);
                } else {
                    // Log warning for keys without values
                    print("No value for key: {s}\n", .{k});
                }
            }
        }

        /// Sets an environment variable in the current process
        ///
        /// Uses C standard library functions to set or unset environment variables
        /// Supports setting a value or clearing an existing variable
        ///
        /// `@param k` Key of the environment variable
        ///
        /// `@param v` Optional value to set (put null to unset)
        ///
        /// @throws Error if setting/unsetting fails
        ///
        /// Example to check all current env variables in the process:
        /// ```zig
        /// var map = try std.process.getEnvMap(allocator);
        /// defer map.deinit();
        /// var it = map.iterator();
        /// while (it.next()) |entry| {
        ///     if (!std.mem.eql(u8, "", entry.value_ptr.*)) std.debug.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        /// }
        /// ```
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

            // Create null-terminated strings for C functions
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
        /// `@param writer` A std.io.Writer to write the output to
        ///
        /// `@param includeSystemVars` Whether to include system variables
        ///
        /// @return Error if writing fails
        ///
        /// Example to write to stdout:
        ///
        /// ```zig
        /// try env.writeAll(std.io.getStdOut().writer(), false);
        /// ```
        pub fn writeAll(self: *Self, writer: anytype, includeSystemVars: bool) !void {
            var envs: std.process.EnvMap = if (includeSystemVars) try std.process.getEnvMap(self.allocator) else self.items;
            defer if (includeSystemVars) envs.deinit();

            if (envs.count() == 0) {
                try writer.writeAll("No environments variables set\n");
                return;
            }

            var it = envs.iterator();
            while (it.next()) |entry| {
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("=");
                try writer.writeAll(entry.value_ptr.*);
                try writer.writeAll("\n");
            }
        }
    };
}

const testing = std.testing;
const fs = std.fs;
const dotenv = @This();

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

    var env = TestEnv.init(allocator);
    defer env.deinit();

    try testing.expectEqual(env.items.count(), 0);
    try testing.expectEqualStrings(env.filename, ".env");
}

test "Env custom filename" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator);
    defer env.deinit();

    // Test setting a custom filename
    try env.load(".env.test", true);
    try testing.expectEqualStrings(env.filename, ".env.test");
}

test "Parse environment variables" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator);
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

    var env = TestEnv.init(allocator);
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

    var env = TestEnv.init(allocator);
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

    var env = TestEnv.init(allocator);
    defer env.deinit();

    try env.load(filename, false);

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

    var env = TestEnv.init(allocator);
    defer env.deinit();

    try env.load(filename, false);

    try testing.expectEqualStrings(env.get("TEST_KEY1"), "value_with_spaces");
    try testing.expectEqualStrings(env.get("TEST_KEY2"), "tabbed_value");
    try testing.expectEqualStrings(env.get("TEST_EMPTY_KEY"), "");
}

test "Write environment variables" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator);
    defer env.deinit();

    const content =
        \\TEST_KEY1=value1
        \\TEST_KEY2=value2
    ;

    try env.parse(@constCast(content));

    // Test writing to a buffer
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try env.writeAll(buffer.writer(), false);

    // Check if the output contains our environment variables
    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "TEST_KEY1=value1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "TEST_KEY2=value2") != null);
}

test "Set process environment variables" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator);
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

    var env = TestEnv.init(allocator);
    defer env.deinit();

    // Should not throw error for non-existent file
    try env.load("non_existent_file.env", true);
    try testing.expectEqual(env.items.count(), 0);
}

test "Handle comments and empty lines" {
    const allocator = testing.allocator;
    const TestEnv = dotenv.Env(EnvKeys);

    var env = TestEnv.init(allocator);
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

        var env = TestEnv.init(allocator);
        defer env.deinit();

        try env.load(filename, false);
        try testing.expectEqualStrings(env.get("TEST_KEY1"), "regular");
    }

    // Test without .env extension
    {
        const filename = "envfile";
        const content = "TEST_KEY1=noextension";

        try createTestEnvFile(filename, content);
        defer deleteTestEnvFile(filename);

        var env = TestEnv.init(allocator);
        defer env.deinit();

        try env.load(filename, false);
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

    var env = TestEnv.init(allocator);
    defer env.deinit();

    // Load from file
    try env.load(filename, false);

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
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try env.writeAll(buffer.writer(), false);

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "TEST_KEY1=integration_value1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "TEST_KEY2=integration_value2") != null);
}
