# v0.10.2

## Highlights

- Fixed `parse` truncating values at the second `=`. Lines are now split on the first `=` only, so base64 padding, passwords and connection strings keep their full value, quoted or not ([#5](https://github.com/xcaeser/zig-dotenv/issues/5)).
- Requires Zig `0.17.0-dev.1818+7051f8e73` or newer; Zig `0.16.0` is not supported.

## Example

```bash
MYSQL_URI=mysql://appuser:p=ssword@127.0.0.1:3306/clone_restaurant
CREDENTIALS_KEY=ZGV2X29ubHlfY3JlZGVudGlhbHNfa2V5XzMyYnl0ZXM=
```

```zig
env.key(.MYSQL_URI); // mysql://appuser:p=ssword@127.0.0.1:3306/clone_restaurant
env.key(.CREDENTIALS_KEY); // ZGV2X29ubHlfY3JlZGVudGlhbHNfa2V5XzMyYnl0ZXM=
```
