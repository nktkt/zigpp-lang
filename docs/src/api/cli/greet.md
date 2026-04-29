# cli/greet.zpp

## Traits

### Greeter

```zig
trait Greeter
```

## Functions

### pickGreeter

```zig
fn pickGreeter(locale_id: []const u8) ?dyn Greeter
```

### printHelp

```zig
fn printHelp() void
```

### printList

```zig
fn printList() void
```

### doGreet

```zig
fn doGreet(g: dyn Greeter, name: []const u8) void
    requires(name.len > 0)
```

### main

```zig
pub fn main() !void
```

## Owned Structs

### Args

```zig
owned struct Args
```

