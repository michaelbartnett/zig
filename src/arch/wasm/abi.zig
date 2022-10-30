//! Classifies Zig types to follow the C-ABI for Wasm.
//! The convention for Wasm's C-ABI can be found at the tool-conventions repo:
//! https://github.com/WebAssembly/tool-conventions/blob/main/BasicCABI.md
//! When not targeting the C-ABI, Zig is allowed to do derail from this convention.
//! Note: Above mentioned document is not an official specification, therefore called a convention.

const std = @import("std");
const Target = std.Target;

const Type = @import("../../type.zig").Type;
const Module = @import("../../Module.zig");

/// Defines how to pass a type as part of a function signature,
/// both for parameters as well as return values.
pub const Class = enum { direct, indirect, none };

const none: [2]Class = .{ .none, .none };
const memory: [2]Class = .{ .indirect, .none };
const direct: [2]Class = .{ .direct, .none };

/// Classifies a given Zig type to determine how they must be passed
/// or returned as value within a wasm function.
/// When all elements result in `.none`, no value must be passed in or returned.
pub fn classifyType(ty: Type, mod: *const Module) [2]Class {
    const target = mod.getTarget();
    if (!ty.hasRuntimeBitsIgnoreComptime(mod)) return none;
    switch (ty.zigTypeTag(mod)) {
        .Struct => {
            if (ty.containerLayout() == .Packed) {
                if (ty.bitSize(mod) <= 64) return direct;
                return .{ .direct, .direct };
            }
            // When the struct type is non-scalar
            if (ty.structFieldCount() > 1) return memory;
            // When the struct's alignment is non-natural
            const field = ty.structFields().values()[0];
            if (field.abi_align != 0) {
                if (field.abi_align > field.ty.abiAlignment(mod)) {
                    return memory;
                }
            }
            return classifyType(field.ty, target);
        },
        .Int, .Enum, .ErrorSet, .Vector => {
            const int_bits = ty.intInfo(mod).bits;
            if (int_bits <= 64) return direct;
            if (int_bits <= 128) return .{ .direct, .direct };
            return memory;
        },
        .Float => {
            const float_bits = ty.floatBits(target);
            if (float_bits <= 64) return direct;
            if (float_bits <= 128) return .{ .direct, .direct };
            return memory;
        },
        .Bool => return direct,
        .Array => return memory,
        .Optional => {
            std.debug.assert(ty.isPtrLikeOptional(mod));
            return direct;
        },
        .Pointer => {
            std.debug.assert(!ty.isSlice());
            return direct;
        },
        .Union => {
            if (ty.containerLayout() == .Packed) {
                if (ty.bitSize(mod) <= 64) return direct;
                return .{ .direct, .direct };
            }
            const layout = ty.unionGetLayout(target);
            std.debug.assert(layout.tag_size == 0);
            if (ty.unionFields().count() > 1) return memory;
            return classifyType(ty.unionFields().values()[0].ty, target);
        },
        .ErrorUnion,
        .Frame,
        .AnyFrame,
        .NoReturn,
        .Void,
        .Type,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .BoundFn,
        .Fn,
        .Opaque,
        .EnumLiteral,
        => unreachable,
    }
}

/// Returns the scalar type a given type can represent.
/// Asserts given type can be represented as scalar, such as
/// a struct with a single scalar field.
pub fn scalarType(ty: Type, mod: *const Module) Type {
    const target = mod.getTarget();
    switch (ty.zigTypeTag(mod)) {
        .Struct => {
            std.debug.assert(ty.structFieldCount() == 1);
            return scalarType(ty.structFieldType(0), mod);
        },
        .Union => {
            const layout = ty.unionGetLayout(target);
            if (layout.payload_size == 0 and layout.tag_size != 0) {
                return scalarType(ty.unionTagTypeSafety().?, mod);
            }
            std.debug.assert(ty.unionFields().count() == 1);
            return scalarType(ty.unionFields().values()[0].ty, mod);
        },
        else => return ty,
    }
}
