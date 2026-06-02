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
const Io = std.Io;
const builtin = @import("builtin");

const LoadOptions = struct {
    /// Defaults to `.env`
    filename: []const u8 = ".env",

    /// When true, include the current process' environment variables into the
    /// parsed/internal map
    include_current_process_envs: bool = false,

    /// If true, set variables in the current process environment; if false, only the
    /// internal library env hashmap is populated
    export_to_process_env: bool = false,
};

/// Initializes a new empty Env struct instance.
///
/// Caller must `deinit`.
pub fn init(process_init: std.process.Init, comptime EnvKey: type) Env(EnvKey) {
    return .init(process_init);
}

fn Env(comptime EnvKey: type) type {
    comptime {
        switch (@typeInfo(EnvKey)) {
            .@"enum" => {},
            else => @compileError("EnvKey must be an enum type"),
        }
    }

    return struct {
        /// Storage for environment variables using an Environ.Map
        map: std.process.Environ.Map,

        internal_process_init: std.process.Init,

        /// GPA used for managing string allocations
        allocator: Allocator,

        io: Io,

        const Self = @This();

        fn init(process_init: std.process.Init) Self {
            return Self{
                .internal_process_init = process_init,
                .io = process_init.io,
                .allocator = process_init.gpa,
                .map = .init(process_init.gpa),
            };
        }

        /// Deallocates all memory associated with the Env struct
        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        /// Loads environment variables from a file
        ///
        /// Supports variable interpolation in values using the format `${OTHER_VAR}`
        /// Interpolated variables are resolved from previously loaded values or the current process environment
        pub fn load(self: *Self, options: LoadOptions) !void {
            var buf: [1024]u8 = undefined;
            const content = try Io.Dir.cwd().readFile(self.io, options.filename, &buf);

            try self.parse(content);

            if (options.include_current_process_envs) {
                try self.loadCurrentProcessEnvs();
            }

            // if (options.export_to_process_env) {
            //     var it = self.items.iterator();
            //     while (it.next()) |entry| {
            //         try self.setProcessEnv(entry.key_ptr.*, entry.value_ptr.*);
            //     }
            // }
        }

        /// Loads the current process environment variables into the Env struct.
        pub fn loadCurrentProcessEnvs(self: *Self) !void {
            var it = self.internal_process_init.environ_map.iterator();

            while (it.next()) |e| {
                try self.map.put(e.key_ptr.*, e.value_ptr.*);
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
            return self.map.get(k) orelse "";
        }

        /// Retrieves the value of a specific environment variable from the provided enum keys
        ///
        /// Example:
        /// ```zig
        /// const openai_key = env.key(.OPENAI_API_KEY);
        /// std.debug.print("OPENAI_API_KEY={s}\n", .{openai_key});
        /// ```
        pub fn key(self: *Self, k: EnvKey) []const u8 {
            return self.map.get(@tagName(k)) orelse "";
        }

        /// Splits the `content` into lines and extracts key-value pairs
        /// Supports comments (lines starting with #) and trims whitespace
        ///
        /// Additionally, supports variable interpolation in values using the format `${OTHER_VAR}` or `$OTHER_VAR
        ///
        /// No need to call this function as it is used in `load` fn. Unless you want to provide your own string.
        pub fn parse(self: *Self, content: []u8) !void {
            var line = std.mem.splitScalar(u8, content, '\n');
            while (line.next()) |l| {
                if (l.len == 0 or l[0] == '#') continue;

                var pair = std.mem.splitScalar(u8, l, '=');
                const k = std.mem.trim(u8, pair.first(), " \t\r");

                if (pair.next()) |value| {
                    var value_trimmed = std.mem.trim(u8, value, " \t\r");
                    if (value_trimmed.len >= 2) {
                        if (value_trimmed[0] == '"' and value_trimmed[value_trimmed.len - 1] == '"') {
                            value_trimmed = value_trimmed[1 .. value_trimmed.len - 1];
                        } else if (value_trimmed[0] == '\'' and value_trimmed[value_trimmed.len - 1] == '\'') {
                            value_trimmed = value_trimmed[1 .. value_trimmed.len - 1];
                        }
                        if (std.mem.startsWith(u8, value_trimmed, "$")) {
                            const var_name = if (std.mem.startsWith(u8, value_trimmed[1..], "{") and std.mem.endsWith(u8, value_trimmed, "}")) value_trimmed[2 .. value_trimmed.len - 1] else value_trimmed[1..];

                            value_trimmed = if (var_name.len > 0) self.internal_process_init.environ_map.get(var_name) orelse "" else "";
                        }
                    }
                    try self.map.put(k, value_trimmed);
                }
            }
        }

        /// Sets or Unsets an environment variable in the current process
        pub fn setProcessEnv(self: *Self, k: []const u8, v: ?[]const u8) !void {
            const os = builtin.os.tag;

            // Import C standard library for setenv/unsetenv
            const c = @cImport({
                @cInclude("stdlib.h");
                if (os == .windows) {
                    @cInclude("windows.h");
                }
            });

            const key_c: [:0]u8 = try self.allocator.dupeSentinel(u8, k, 0);
            defer self.allocator.free(key_c);

            if (v) |val| {
                const value_c: [:0]u8 = try self.allocator.dupeSentinel(u8, val, 0);
                defer self.allocator.free(value_c);

                if (c.setenv(key_c, value_c, 1) != 0) {
                    return error.SetEnvFailed;
                }
            } else {
                if (c.unsetenv(key_c) != 0) {
                    return error.UnsetEnvFailed;
                }
            }
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
