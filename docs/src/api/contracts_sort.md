# contracts_sort.zpp

## Traits

### Ord

```zig
trait Ord
```

## Functions

### isSorted

```zig
fn isSorted(comptime T: type, xs: []const T) bool where T: Ord
```

### binarySearch

```zig
fn binarySearch(comptime T: type, xs: []const T, target: T) ?usize
    where T: Ord
    requires(isSorted(T, xs))
```

### main

```zig
pub fn main() !void
```

