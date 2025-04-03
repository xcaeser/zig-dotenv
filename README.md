# zig-dotenv

<div>

A powerful Zig library for loading, parsing, and managing environment variables from .env files.

[![Version](https://img.shields.io/badge/Zig_Version-0.14.0-orange.svg?logo=zig)](README.md)
[![MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

</div>

## ✅ Features

- Load environment variables from `.env` files
- Append or write to `.env` files
- Type-safe access using enums
- Modify the **current process** environment (via `setenv` / `SetEnvironmentVariable`)
- Clean API for parsing and managing `.env` values

## 🚀 Usage

```zig
const std = @import("std");
const dotenv = @import("dotenv");

pub const EnvKeys = enum {
    OPENAI_API_KEY,
    AWS_ACCESS_KEY_ID,
    COGNITO_CLIENT_SECRET,
    S3_BUCKET,
};

pub const Env = dotenv.Env(EnvKeys);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator, true);
    defer env.deinit();

    // Load from .env.local (or .env if null)
    try env.load(".env.local", true); // `silent = true` to suppress missing file errors

    // Access values
    const openai = env.key(.OPENAI_API_KEY);
    std.debug.print("OPENAI_API_KEY={s}\n", .{openai});

    const aws_key = env.get("AWS_ACCESS_KEY_ID");
    std.debug.print("AWS_ACCESS_KEY_ID={s}\n", .{aws_key});
}
```

## 📄 Example `.env` file

```dotenv
OPENAI_API_KEY=sk-your-api-key-here
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE

S3_BUCKET="my-bucket"
COGNITO_CLIENT_SECRET='abcdef123456'
```

## 📦 Installation

### Option 1: `zig fetch`

```bash
zig fetch --save=dotenv https://github.com/xcaeser/zig-dotenv/archive/v0.4.0.tar.gz
```

### Option 2: `build.zig.zon`

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .dotenv = .{
            .url = "https://github.com/xcaeser/zig-dotenv/archive/v0.4.0.tar.gz",
            .hash = "...", // use zig's suggested hash
        },
    },
}
```

### Add to `build.zig`

```zig
const dotenv_dep = b.dependency("dotenv", .{ .target = target, .optimize = optimize });

exe.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
exe.linkLibC(); // Required for setenv/unsetenv

// Optional for testing
exe_unit_tests.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
```

### 📚 API Summary

#### `Env(EnvKey)` type

Creates a generic environment manager with the following methods:

| Signature                                                                                            | Description                                    |
| ---------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| `fn init(allocator: std.mem.Allocator, includeCurrentProcessEnvs: bool) Env`                         | Initialize a new environment manager           |
| `fn deinit(self: *Env) void`                                                                         | Frees memory and internal data                 |
| `fn load(self: *Env, filename: ?[]const u8, silent: bool) !void`                                     | Load a `.env` file into the environment        |
| `fn parse(self: *Env, content: []u8) !void`                                                          | Parse raw `.env`-formatted text                |
| `fn get(self: *Env, key: []const u8) []const u8`                                                     | Get value by string key (panics if missing)    |
| `fn key(self: *Env, key: EnvKey) []const u8`                                                         | Get value by enum key (panics if missing)      |
| `fn setProcessEnv(self: *Env, key: []const u8, value: ?[]const u8) !void`                            | Set or unset a variable in the current process |
| `fn writeAllEnvPairs(self: *Env, writer: anytype, includeSystemVars: bool) !void`                    | Write all variables to a writer                |
| `fn writeEnvPairToFile(self: *Env, key: []const u8, value: []const u8, filename: ?[]const u8) !void` | Append a `key=value` pair to file              |

## 🤝 Contributing

Issues and pull requests welcome.

## 📝 License

MIT
