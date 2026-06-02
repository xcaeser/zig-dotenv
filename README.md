# zig-dotenv

<div>

A powerful Zig library for loading, parsing, and managing environment variables from `.env` files.

[![Version](https://img.shields.io/badge/Zig_Version-0.16.0-orange.svg?logo=zig)](README.md)
[![MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg?logo=cachet)](LICENSE)
[![Version](https://img.shields.io/badge/dotenv-v0.9.0-green)](https://github.com/xcaeser/zig-dotenv/releases)

</div>

## Docs:

[dotenv reference docs](https://xcaeser.github.io/zig-dotenv)

## ✅ Features

- Load environment variables from `.env` files
- Type-safe access using enums
- Read from and copy the current process environment map
- Modify the **current process environment** with `setProcessEnv`
- Supports comments, quoted values, and whitespace trimming
- Supports `$KEY` and `${KEY}` interpolation from the process environment map
- Missing keys return an empty string
- Clean, testable API

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

pub fn main(process_init: std.process.Init) !void {
    var env = dotenv.init(process_init, EnvKeys);
    defer env.deinit();

    try env.load(.{
        .filename = ".env.local",
        .include_current_process_envs = true,
    });

    const openai = env.key(.OPENAI_API_KEY);
    std.debug.print("OPENAI_API_KEY={s}\n", .{openai});

    const aws_key = env.get("AWS_ACCESS_KEY_ID");
    std.debug.print("AWS_ACCESS_KEY_ID={s}\n", .{aws_key});
}
```

## 📄 Example `.env` File

```dotenv
OPENAI_API_KEY=sk-your-api-key-here
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
S3_BUCKET="my-bucket"
COGNITO_CLIENT_SECRET='abcdef123456'
HOME_DIR=$HOME
USER_NAME=${USER}
```

## 📦 Installation

### using `zig fetch`

```bash
zig fetch --save=dotenv https://github.com/xcaeser/zig-dotenv/archive/v0.9.0.tar.gz
```

### Add to `build.zig`

```zig
const dotenv_dep = b.dependency("dotenv", .{ .target = target, .optimize = optimize });

exe.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));

// Optional: add for unit tests
exe_unit_tests.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
```

## 📚 API Summary

### Initialization

`zig-dotenv` uses Zig `0.16.0`'s `std.process.Init` API. Accept it in `main`, then create an env manager with your enum type:

```zig
pub fn main(process_init: std.process.Init) !void {
    var env = dotenv.init(process_init, EnvKeys);
    defer env.deinit();
}
```

### Env API

| Method                                                  | Description                                      |
| ------------------------------------------------------- | ------------------------------------------------ |
| `dotenv.init(process_init, EnvKey)`                     | Initializes a new Env manager                    |
| `deinit()`                                              | Frees all allocated memory                       |
| `load(.{ .filename, .include_current_process_envs })`   | Loads variables from a `.env` file               |
| `loadCurrentProcessEnvs()`                              | Copies process variables into the internal map   |
| `parse(content)`                                        | Parses raw `.env`-formatted text                 |
| `get("KEY")`                                            | Gets a value by string key, or `""` if missing   |
| `key(.ENUM_KEY)`                                        | Gets a value by enum key, or `""` if missing     |
| `setProcessEnv("KEY", "VALUE")`                         | Sets a process environment variable              |
| `setProcessEnv("KEY", null)`                            | Unsets a process environment variable            |

### Load Options

| Option                         | Default | Description                                      |
| ------------------------------ | ------- | ------------------------------------------------ |
| `filename`                     | `.env`  | File to load                                     |
| `include_current_process_envs` | `false` | Copies `process_init.environ_map` into the map   |
| `export_to_process_env`        | `false` | Reserved; not currently implemented             |

## 🧪 Testing

Run:

```bash
zig build test
```

Includes tests for parsing, file I/O, interpolation, process environment loading, and lookup behavior.

## 🤝 Contributing

Issues and PRs welcome! Star the repo if it helped you.

## 📝 License

MIT – see [LICENSE](LICENSE).
