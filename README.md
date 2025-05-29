# zig-dotenv

<div>

A powerful Zig library for loading, parsing, and managing environment variables from `.env` files.

[![Version](https://img.shields.io/badge/Zig_Version-0.14.0-orange.svg?logo=zig)](README.md)
[![MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg?logo=cachet)](LICENSE)
[![Version](https://img.shields.io/badge/dotenv-v0.6.1-green)](https://github.com/xcaeser/zig-dotenv/releases)

</div>

---

## ✅ Features

- Load environment variables from `.env` files
- Append or write `key=value` pairs to `.env` files
- Type-safe access using enums
- Modify the **current process environment** (`setenv`, `SetEnvironmentVariable`)
- Supports comments, quoted values, and whitespace trimming
- Graceful fallback and silent error modes
- Clean, testable API

---

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

const Env = dotenv.Env(EnvKeys);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator, true);
    defer env.deinit();

    try env.load(.{ .filename = ".env.local", .set_envs_inprocess = true, .silent = true });

    const openai = env.key(.OPENAI_API_KEY);
    std.debug.print("OPENAI_API_KEY={s}\n", .{openai});

    const aws_key = env.get("AWS_ACCESS_KEY_ID");
    std.debug.print("AWS_ACCESS_KEY_ID={s}\n", .{aws_key});
}
```

---

## 📄 Example `.env` File

```dotenv
OPENAI_API_KEY=sk-your-api-key-here
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
S3_BUCKET="my-bucket"
COGNITO_CLIENT_SECRET='abcdef123456'
```

---

## 📦 Installation

### using `zig fetch`

```bash
zig fetch --save=dotenv https://github.com/xcaeser/zig-dotenv/archive/v0.6.1.tar.gz
```

### Add to `build.zig`

```zig
const dotenv_dep = b.dependency("dotenv", .{ .target = target, .optimize = optimize });

exe.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
exe.linkLibC(); // Required for setenv/unsetenv

// Optional: add for unit tests
exe_unit_tests.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
```

---

## 📚 API Summary

### `Env(EnvKey)` type

A reusable struct for managing environment variables:

| Method                                                  | Description                                   |
| ------------------------------------------------------- | --------------------------------------------- |
| `init(allocator, includeCurrentProcessEnvs)`            | Initializes a new Env manager                 |
| `deinit()`                                              | Frees all allocated memory                    |
| `load(.{ filename, set_envs_inprocess, silent })`       | Loads variables from a `.env` file            |
| `parse(content)`                                        | Parses raw `.env`-formatted text              |
| `get("KEY")`                                            | Get a value by string key (panics if missing) |
| `key(.ENUM_KEY)`                                        | Get a value by enum key (panics if missing)   |
| `setProcessEnv("KEY", "VALUE")`                         | Set or unset environment variable             |
| `writeAllEnvPairs(writer, includeSystemVars)`           | Write all variables to a writer               |
| `writeEnvPairToFile("KEY", "VALUE", optional_filename)` | Append a `key=value` line to a file           |

---

## 🧪 Testing

Run:

```bash
zig build test
```

Includes tests for parsing, file I/O, process environment setting, and edge cases.

---

## 🤝 Contributing

Issues and PRs welcome! Star the repo if it helped you.

---

## 📝 License

MIT – see [LICENSE](LICENSE).
