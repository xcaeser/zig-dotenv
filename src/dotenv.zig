//! Dotenv: Loading, parsing, and setting environment variables from a .env file (or any file) with ease.
//!
//! Example:
//!
//! ```zig
//! const std = @import("std");
//! const dotenv = @import("dotenv");
//!
//! const EnvKeys = enum {
//!     OPENAI_API_KEY,
//!     AWS_ACCESS_KEY_ID,
//! };
//!
//! pub fn main(process_init: std.process.Init) !void {
//!     var env = dotenv.init(process_init, EnvKeys);
//!     defer env.deinit();
//!
//!     try env.load(.{ .filename = ".env.local" });
//!
//!     const openai_key = env.key(.OPENAI_API_KEY);
//!     std.debug.print("OPENAI_API_KEY={s}\n", .{openai_key});
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Io = std.Io;

/// Largest dotenv file `load` reads. A larger file is an error, never a
/// silently shortened one.
pub const max_file_bytes = 1024 * 1024;

pub const LoadOptions = struct {
    /// Defaults to `.env`
    filename: []const u8 = ".env",

    /// When true, include the current process' environment variables into the
    /// parsed/internal map. They win over values from the file, also when
    /// `export_to_process_env` is set.
    include_current_process_envs: bool = false,

    /// If true, set variables in the current process environment; if false, only the
    /// internal library env hashmap is populated
    export_to_process_env: bool = false,
};

/// Initializes a new empty Env struct instance.
///
/// Caller must `deinit`.
pub fn init(process_init: std.process.Init, comptime EnvKey: type) Env(EnvKey) {
    return Env(EnvKey).init(process_init);
}

pub fn Env(comptime EnvKey: type) type {
    comptime {
        switch (@typeInfo(EnvKey)) {
            .@"enum" => {},
            else => @compileError("EnvKey must be an enum type"),
        }
    }

    return struct {
        /// Storage for environment variables using an Environ.Map
        /// Environment variables loaded by dotenv.
        map: std.process.Environ.Map,

        /// Application environment supplied by std.process.Init.
        process_env: *std.process.Environ.Map,

        /// GPA used for managing string allocations
        allocator: Allocator,

        io: Io,

        const Self = @This();

        fn init(process_init: std.process.Init) Self {
            return Self{
                .process_env = process_init.environ_map,
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
            // The limit is exclusive: a file of exactly `max_file_bytes` loads,
            // a larger one fails with `error.StreamTooLong`.
            const content = try Io.Dir.cwd().readFileAlloc(
                self.io,
                options.filename,
                self.allocator,
                .limited(max_file_bytes + 1),
            );
            defer self.allocator.free(content);

            try self.parse(content);

            // Include before export, so process values win in both maps
            if (options.include_current_process_envs) {
                try self.map.putAll(self.process_env);
            }

            if (options.export_to_process_env) {
                try self.process_env.putAll(&self.map);
            }
        }

        /// Loads the current process environment variables into the Env struct.
        pub fn loadCurrentProcessEnvs(self: *Self) !void {
            try self.map.putAll(self.process_env);
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
        /// Additionally, supports variable interpolation in values using the format `${OTHER_VAR}` or `$OTHER_VAR`.
        /// Single-quoted values are kept literal.
        ///
        /// No need to call this function as it is used in `load` fn. Unless you want to provide your own string.
        pub fn parse(self: *Self, content: []const u8) !void {
            var line = std.mem.splitScalar(u8, content, '\n');
            while (line.next()) |raw| {
                const l = std.mem.trimStart(u8, raw, " \t");
                if (l.len == 0 or l[0] == '#') continue;

                // Split on the first '=' only, values may contain '=' themselves
                if (std.mem.cutScalar(u8, l, '=')) |pair| {
                    const k = std.mem.trim(u8, pair[0], " \t\r");
                    // Environ.Map asserts the key is valid (non-empty, no NUL),
                    // so skip such lines like any other malformed one
                    if (!std.process.Environ.Map.validateKeyForPut(k)) continue;
                    const value = pair[1];

                    var value_trimmed = std.mem.trim(u8, value, " \t\r");
                    if (value_trimmed.len >= 2) {
                        if (value_trimmed[0] == '"' and value_trimmed[value_trimmed.len - 1] == '"') {
                            value_trimmed = value_trimmed[1 .. value_trimmed.len - 1];
                        } else if (value_trimmed[0] == '\'' and value_trimmed[value_trimmed.len - 1] == '\'') {
                            // Single quotes keep the value literal, no interpolation
                            try self.map.put(k, value_trimmed[1 .. value_trimmed.len - 1]);
                            continue;
                        }
                        if (std.mem.startsWith(u8, value_trimmed, "$")) {
                            const braced = std.mem.startsWith(u8, value_trimmed[1..], "{") and std.mem.endsWith(u8, value_trimmed, "}");
                            const var_name = if (braced) value_trimmed[2 .. value_trimmed.len - 1] else value_trimmed[1..];

                            // Only a whole `$NAME` or `${NAME}` is a reference; any other
                            // value starting with '$' (a bcrypt hash, "$5 off") is kept as is
                            if (isVarName(var_name)) {
                                value_trimmed = self.map.get(var_name) orelse
                                    self.process_env.get(var_name) orelse "";
                            }
                        }
                    }
                    try self.map.put(k, value_trimmed);
                }
            }
        }

        /// Sets or Unsets an environment variable in the current process
        pub fn setProcessEnv(self: *Self, k: []const u8, v: ?[]const u8) !void {
            if (v) |value| {
                try self.process_env.put(k, value);
            } else {
                _ = self.process_env.swapRemove(k);
            }
        }
    };
}

/// True when `name` is a letter or '_' followed by letters, digits or '_'
fn isVarName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

// Define test environment keys
const EnvKeys = enum(u8) {
    TEST_KEY1,
    TEST_KEY2,
    TEST_EMPTY_KEY,
    TEST_NUMERIC_VALUE,
};

fn testProcessInit(
    process_env: *std.process.Environ.Map,
    arena: *std.heap.ArenaAllocator,
) std.process.Init {
    return .{
        .minimal = undefined,
        .arena = arena,
        .gpa = testing.allocator,
        .io = testing.io,
        .environ_map = process_env,
        .preopens = .empty,
    };
}

test "init creates an empty dotenv map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try testing.expectEqual(@as(std.process.Environ.Map.Size, 0), env.map.count());
    try testing.expectEqualStrings("", env.get("MISSING_KEY"));
}

test "parse handles comments whitespace quotes and empty values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    const content =
        \\# ignored comment
        \\
        \\ TEST_KEY1 = "value1"
        \\TEST_KEY2='value2'
        \\TEST_EMPTY_KEY=
        \\TEST_NUMERIC_VALUE=123
        \\UNQUOTED = value with spaces
    ;

    try env.parse(content);

    try testing.expectEqual(@as(std.process.Environ.Map.Size, 5), env.map.count());
    try testing.expectEqualStrings("value1", env.get("TEST_KEY1"));
    try testing.expectEqualStrings("value2", env.get("TEST_KEY2"));
    try testing.expectEqualStrings("", env.get("TEST_EMPTY_KEY"));
    try testing.expectEqualStrings("123", env.get("TEST_NUMERIC_VALUE"));
    try testing.expectEqualStrings("value with spaces", env.get("UNQUOTED"));
}

test "parse keeps '=' inside values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    const content =
        \\MYSQL_URI=mysql://appuser:p=ssword@127.0.0.1:3306/clone_restaurant
        \\CREDENTIALS_KEY=ZGV2X29ubHlfY3JlZGVudGlhbHNfa2V5XzMyYnl0ZXM=
        \\QUOTED = "a=b=c"
        \\NO_EQUALS_SIGN
    ;

    try env.parse(content);

    try testing.expectEqual(@as(std.process.Environ.Map.Size, 3), env.map.count());
    try testing.expectEqualStrings("mysql://appuser:p=ssword@127.0.0.1:3306/clone_restaurant", env.get("MYSQL_URI"));
    try testing.expectEqualStrings("ZGV2X29ubHlfY3JlZGVudGlhbHNfa2V5XzMyYnl0ZXM=", env.get("CREDENTIALS_KEY"));
    try testing.expectEqualStrings("a=b=c", env.get("QUOTED"));
}

test "parse handles CRLF line endings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try env.parse("# comment\r\nTEST_KEY1=value1\r\nTEST_KEY2 = \"value2\"\r\n");

    try testing.expectEqual(@as(std.process.Environ.Map.Size, 2), env.map.count());
    try testing.expectEqualStrings("value1", env.key(.TEST_KEY1));
    try testing.expectEqualStrings("value2", env.key(.TEST_KEY2));
}

test "parse skips indented comments and lines without a valid key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try env.parse("=no_key\n  =no_key\n\x00=nul_key\n  # COMMENTED=1\n\t#TABBED=1\nTEST_KEY1=kept\n");

    try testing.expectEqual(@as(std.process.Environ.Map.Size, 1), env.map.count());
    try testing.expectEqualStrings("kept", env.key(.TEST_KEY1));
}

test "get and key return parsed values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    const content =
        \\TEST_KEY1=value1
        \\TEST_KEY2=value2
    ;

    try env.parse(content);

    try testing.expectEqualStrings("value1", env.get("TEST_KEY1"));
    try testing.expectEqualStrings("value1", env.key(.TEST_KEY1));
    try testing.expectEqualStrings("value2", env.key(.TEST_KEY2));
    try testing.expectEqualStrings("", env.key(.TEST_EMPTY_KEY));
}

test "parse interpolates from process env map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();
    try process_env.put("SOURCE_VALUE", "from_process_env");

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    const content =
        \\TEST_KEY1=$SOURCE_VALUE
        \\TEST_KEY2=${SOURCE_VALUE}
        \\TEST_EMPTY_KEY=$DOES_NOT_EXIST
    ;

    try env.parse(content);

    try testing.expectEqualStrings("from_process_env", env.get("TEST_KEY1"));
    try testing.expectEqualStrings("from_process_env", env.get("TEST_KEY2"));
    try testing.expectEqualStrings("", env.get("TEST_EMPTY_KEY"));
}

test "parse interpolates from previously parsed values before process env" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();
    try process_env.put("SOURCE_VALUE", "from_process_env");

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    const content =
        \\SOURCE_VALUE=from_dotenv
        \\TEST_KEY1=$SOURCE_VALUE
        \\TEST_KEY2=${SOURCE_VALUE}
    ;

    try env.parse(content);

    try testing.expectEqualStrings("from_dotenv", env.get("TEST_KEY1"));
    try testing.expectEqualStrings("from_dotenv", env.get("TEST_KEY2"));
}

test "parse keeps values that are not a variable reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();
    try process_env.put("SOURCE_VALUE", "from_process_env");

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    const content =
        \\HASH=$2b$10$abcdef
        \\PRICE="$5 off"
        \\UNCLOSED=${SOURCE_VALUE
        \\EMPTY_BRACES=${}
        \\SINGLE='$SOURCE_VALUE'
        \\DOUBLE="$SOURCE_VALUE"
    ;

    try env.parse(content);

    try testing.expectEqualStrings("$2b$10$abcdef", env.get("HASH"));
    try testing.expectEqualStrings("$5 off", env.get("PRICE"));
    try testing.expectEqualStrings("${SOURCE_VALUE", env.get("UNCLOSED"));
    try testing.expectEqualStrings("${}", env.get("EMPTY_BRACES"));
    try testing.expectEqualStrings("$SOURCE_VALUE", env.get("SINGLE"));
    try testing.expectEqualStrings("from_process_env", env.get("DOUBLE"));
}

test "loadCurrentProcessEnvs copies supplied process env map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();
    try process_env.put("TEST_KEY1", "current_value1");
    try process_env.put("TEST_KEY2", "current_value2");

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try env.loadCurrentProcessEnvs();

    try testing.expectEqualStrings("current_value1", env.get("TEST_KEY1"));
    try testing.expectEqualStrings("current_value2", env.key(.TEST_KEY2));
}

test "setProcessEnv sets and unsets values in supplied process env map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try env.setProcessEnv("TEST_KEY1", "set_value");
    try testing.expectEqualStrings("set_value", process_env.get("TEST_KEY1").?);

    try env.setProcessEnv("TEST_KEY1", null);
    try testing.expect(process_env.get("TEST_KEY1") == null);
}

test "load reads dotenv file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    const filename = ".zig-dotenv-test.env";
    defer Io.Dir.cwd().deleteFile(testing.io, filename) catch {};
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = filename,
        .data =
        \\TEST_KEY1=file_value1
        \\TEST_KEY2=file_value2
        ,
    });

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try env.load(.{ .filename = filename });

    try testing.expectEqualStrings("file_value1", env.get("TEST_KEY1"));
    try testing.expectEqualStrings("file_value2", env.key(.TEST_KEY2));
}

test "load reads a file past its first kilobyte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    const filename = ".zig-dotenv-test-long.env";
    defer Io.Dir.cwd().deleteFile(testing.io, filename) catch {};
    const padding: [2000]u8 = @splat('x');
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = filename,
        .data = "TEST_KEY1=first\n# " ++ padding ++ "\nTEST_KEY2=last\n",
    });

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try env.load(.{ .filename = filename });

    try testing.expectEqualStrings("first", env.key(.TEST_KEY1));
    try testing.expectEqualStrings("last", env.key(.TEST_KEY2));
}

test "load exports parsed values to supplied process env map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();
    try process_env.put("TEST_KEY1", "old_value");

    const filename = ".zig-dotenv-export-test.env";
    defer Io.Dir.cwd().deleteFile(testing.io, filename) catch {};
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = filename,
        .data =
        \\TEST_KEY1=exported_value
        \\TEST_KEY2=new_value
        ,
    });

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try env.load(.{ .filename = filename, .export_to_process_env = true });

    try testing.expectEqualStrings("exported_value", process_env.get("TEST_KEY1").?);
    try testing.expectEqualStrings("new_value", process_env.get("TEST_KEY2").?);
}

test "load includes supplied process env values and lets them override parsed values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();
    try process_env.put("TEST_KEY1", "process_value");
    try process_env.put("PROCESS_ONLY", "included_value");

    const filename = ".zig-dotenv-include-test.env";
    defer Io.Dir.cwd().deleteFile(testing.io, filename) catch {};
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = filename,
        .data =
        \\TEST_KEY1=file_value
        ,
    });

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try env.load(.{ .filename = filename, .include_current_process_envs = true });

    try testing.expectEqualStrings("process_value", env.get("TEST_KEY1"));
    try testing.expectEqualStrings("included_value", env.get("PROCESS_ONLY"));
}

test "load keeps process env values when both including and exporting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();
    try process_env.put("TEST_KEY1", "process_value");

    const filename = ".zig-dotenv-include-export-test.env";
    defer Io.Dir.cwd().deleteFile(testing.io, filename) catch {};
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = filename,
        .data =
        \\TEST_KEY1=file_value
        \\TEST_KEY2=file_only
        ,
    });

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try env.load(.{ .filename = filename, .include_current_process_envs = true, .export_to_process_env = true });

    try testing.expectEqualStrings("process_value", env.key(.TEST_KEY1));
    try testing.expectEqualStrings("process_value", process_env.get("TEST_KEY1").?);
    try testing.expectEqualStrings("file_only", env.key(.TEST_KEY2));
    try testing.expectEqualStrings("file_only", process_env.get("TEST_KEY2").?);
}

test "load fails on a missing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try testing.expectError(error.FileNotFound, env.load(.{ .filename = ".zig-dotenv-test-missing.env" }));
}

test "load accepts a file of max_file_bytes and rejects a larger one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var process_env = std.process.Environ.Map.init(testing.allocator);
    defer process_env.deinit();

    const data = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(data);
    @memset(data, '#');
    @memcpy(data[0..13], "TEST_KEY1=ok\n");

    const filename = ".zig-dotenv-test-max.env";
    defer Io.Dir.cwd().deleteFile(testing.io, filename) catch {};

    var env = init(testProcessInit(&process_env, &arena), EnvKeys);
    defer env.deinit();

    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = filename, .data = data[0..max_file_bytes] });
    try env.load(.{ .filename = filename });
    try testing.expectEqualStrings("ok", env.key(.TEST_KEY1));

    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = filename, .data = data });
    try testing.expectError(error.StreamTooLong, env.load(.{ .filename = filename }));
}
