# v0.9.0

## Highlights

- Updated the package for Zig `0.16.0`.
- Moved initialization to the Zig `std.process.Init` API:
  - Use `dotenv.init(process_init, EnvKeys)` from a `main(process_init: std.process.Init)`.
  - The library now uses `process_init.gpa`, `process_init.io`, and `process_init.environ_map`.
- Switched internal storage to `std.process.Environ.Map`.
- Added support for loading current process environment values through `loadCurrentProcessEnvs()` or `load(.{ .include_current_process_envs = true })`.
- Added focused tests for initialization, parsing, enum/string lookup, interpolation, current environment loading, and file loading.

## Breaking Changes

- `dotenv.Env(EnvKeys).init(allocator, include_current_process_envs)` has been replaced by `dotenv.init(process_init, EnvKeys)`.
- `load` options changed:
  - `filename` now defaults to `.env`.
  - `include_current_process_envs` controls whether the supplied process environment map is copied into the dotenv map.
  - `export_to_process_env` exists in the options struct but is not currently implemented.
- Missing values from `get` and `key` now return an empty string instead of panicking.
- The previous writer helpers are no longer part of the current API:
  - `writeAllEnvPairs`
  - `writeEnvPairToFile`

## Migration

Old initialization:

```zig
var env = dotenv.Env(EnvKeys).init(allocator, true);
defer env.deinit();
```

New initialization:

```zig
pub fn main(process_init: std.process.Init) !void {
    var env = dotenv.init(process_init, EnvKeys);
    defer env.deinit();

    try env.load(.{
        .filename = ".env.local",
        .include_current_process_envs = true,
    });
}
```
