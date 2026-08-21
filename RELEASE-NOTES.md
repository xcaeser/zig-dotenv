# v0.10.1

## Highlights

- Requires Zig `0.17.0-dev.1818+7051f8e73` or newer; Zig `0.16.0` is not supported.
- Implemented `export_to_process_env` by copying parsed values into the environment map supplied through `std.process.Init`.
- Updated `setProcessEnv` to set and unset values in that supplied environment map without relying on libc.
- Interpolation now checks previously parsed dotenv values before falling back to the supplied process environment map.
- Made `Env` and `LoadOptions` public.
- Expanded tests for interpolation precedence, process-map mutation, import behavior, and export behavior.

## Breaking Changes

- `setProcessEnv` now mutates `process_init.environ_map`; it no longer calls the operating system's `setenv` or `unsetenv` functions.
- `export_to_process_env` exports to `process_init.environ_map`, not directly to the operating system environment.

## Usage

```zig
pub fn main(process_init: std.process.Init) !void {
    var env = dotenv.init(process_init, EnvKeys);
    defer env.deinit();

    try env.load(.{
        .filename = ".env.local",
        .export_to_process_env = true,
    });
}
```
