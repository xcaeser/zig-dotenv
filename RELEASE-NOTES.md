# v0.10.3

## Highlights

- Fixed `load` reading only the first 1024 bytes of a file. Keys past that point were missing or cut off mid-value, with no error. The file is now read whole.
- A dotenv file larger than 1 MiB (`dotenv.max_file_bytes`) fails with `error.StreamTooLong` instead of being shortened.
- Requires Zig `0.17.0-dev.1818+7051f8e73` or newer; Zig `0.16.0` is not supported.
