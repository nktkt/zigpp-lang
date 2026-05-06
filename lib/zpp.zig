//! Zig++ runtime support library.
//! Lowered `.zpp` source imports this module via `@import("zpp")`.

const std = @import("std");

pub const trait = @import("traits.zig");
pub const owned = @import("owned.zig");
pub const contract = @import("contracts.zig");
pub const dyn_mod = @import("dyn.zig");
pub const async_mod = @import("async.zig");
pub const testing_ = @import("testing.zig");
pub const derive = @import("derive.zig");
pub const writer = @import("writer.zig");

pub const Dyn = dyn_mod.Dyn;
pub const VTableOf = trait.VTableOf;
pub const implFor = trait.implFor;

pub const Owned = owned.Owned;
pub const ArenaScope = owned.ArenaScope;
pub const DeinitGuard = owned.DeinitGuard;

pub const requires = contract.requires;
pub const ensures = contract.ensures;
pub const invariant = contract.invariant;

test "barrel exports compile" {
    _ = trait;
    _ = owned;
    _ = contract;
    _ = dyn_mod;
    _ = async_mod;
    _ = testing_;
    _ = derive;
    _ = Dyn;
}

test "barrel re-exports resolve" {
    const VT = VTableOf(.{
        .{ "ping", *const fn (*anyopaque) u32 },
    });
    try std.testing.expect(@hasField(VT, "ping"));
}
