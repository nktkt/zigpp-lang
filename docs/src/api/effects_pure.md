# effects_pure.zpp

## Functions

### fnv1a

```zig
fn fnv1a(bytes: []const u8) u64 effects(.noalloc, .noio)
```

### loadAndHash

```zig
fn loadAndHash(a: std.mem.Allocator, path: []const u8) !u64 effects(.alloc, .io)
```

### main

```zig
pub fn main() !void
```

