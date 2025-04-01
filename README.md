# zig-dotenv

A powerful Zig library for loading and managing environment variables from .env files.

## Features

- Load environment variables from `.env` files
- Type-safe access to environment variables via enums
- Set environment variables in the current process (not just the child process) - uses C standard library functions
- Parse and manage environment variables with a clean API

## Usage

```zig
const std = @import("std");
const dotenv = @import("dotenv");

// Define your environment keys as an enum
pub const EnvKeys = enum(u8) {
    OPENAI_API_KEY,
    AWS_ACCESS_KEY_ID,
    COGNITO_CLIENT_SECRET,
    S3_BUCKET,
};

// Create a type-safe environment manager
pub const Env = dotenv.Env(EnvKeys);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Initialize environment manager
    var env = Env.init(allocator);
    defer env.deinit();

    // Load from .env.local (or pass null to load from .env)
    try env.load(".env.local", true); // silent=true to suppress error messages if .env.local is not found

    // Access env vars using type-safe enum keys
    const openai = env.key(.OPENAI_API_KEY);
    std.debug.print("OPENAI_API_KEY={s}\n", .{openai});

    // Or access by string
    const aws_key = env.get("AWS_ACCESS_KEY_ID");
    std.debug.print("AWS_ACCESS_KEY_ID={s}\n", .{aws_key});
}
```

## Example .env File

```
# API Keys
OPENAI_API_KEY=sk-your-api-key-here
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE

# Other configuration
S3_BUCKET="my-bucket"
COGNITO_CLIENT_SECRET='abcdef123456'
```

## Installation

### Step 1: add to your project

#### Option 1: Add to your project

```bash
zig fetch --save=dotenv https://github.com/xcaeser/zig-dotenv/archive/v0.2.0.tar.gz
```

#### Option 2: Add to your `build.zig.zon` directly

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .dotenv = .{
            .url = "https://github.com/xcaeser/zig-dotenv/archive/v0.2.0.tar.gz",
            .hash = "...",
        },
    },
}
```

### Step 2: Add to your `build.zig`:

```zig
const dotenv_dep = b.dependency("dotenv", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
exe.linkLibC(); // important to add because we're using stdlib.h

// Add to tests
exe_unit_tests.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
```

## API Reference

### Env(EnvKey) type

Creates a generic environment variable management struct that handles loading, parsing, and accessing environment variables.

#### Methods

- `init(allocator)` - Initializes a new environment manager
- `initWithProcessEnvs(allocator)` - Initializes a new environment manager with the current process environment variables
- `deinit()` - Frees all resources
- `load(?[]const u8, bool)` - Loads variables from a file (default: ".env")
- `get([]const u8)` - Gets a variable by string name
- `key(EnvKey)` - Gets a variable using an enum key
- `setProcessEnv([]const u8, ?[]const u8)` - Sets an environment variable in the current process. If value is null, unsets the variable
- `writeAll(writer, includeSystemVars)` - Writes all variables to a writer

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

MIT
