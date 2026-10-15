# v0.11.0

## Highlights

- Fixed values starting with `$` being loaded as empty strings. A bcrypt hash (`$2b$10$...`), `"$5 off"` or an unclosed `${X` now keep their text; only a whole `$NAME` or `${NAME}` is interpolated.
- Single-quoted values are kept literal: `PW='$ecret'` loads as `$ecret`.
- Fixed `parse` crashing on a line with an empty key, such as `=value`. Such lines are skipped, and so are indented comments (`  # FOO=1` no longer sets a key named `# FOO`).
- With both `include_current_process_envs` and `export_to_process_env` set, process environment values now win over the file, as they already did with `include_current_process_envs` alone.
- `parse` takes `[]const u8`, so callers no longer need `@constCast`.
- The module no longer links libc. If your project relied on it for libc, set `.link_libc = true` on your own module.
- Requires Zig `0.17.0` or newer.
