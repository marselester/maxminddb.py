const std = @import("std");

const pyoz = @import("PyOZ");
const maxminddb = @import("maxminddb");

const allocator = std.heap.smp_allocator;

/// Reads MaxMind DB files.
pub const Reader = struct {
    db: maxminddb.Reader,
    is_closed: bool,

    const Self = @This();

    /// Opens a MaxMind DB file, for example:
    /// r = maxmind.Reader('GeoLite2-City.mmdb')
    pub fn __new__(path: []const u8) !Reader {
        return .{
            .db = try maxminddb.Reader.mmap(allocator, path, .{}),
            .is_closed = false,
        };
    }

    /// Closes a db when the Reader is deleted, for example:
    /// del r
    pub fn __del__(self: *Self) void {
        self.close();
    }

    /// Context manager protocol, for example:
    /// with maxmind.Reader('GeoLite2-City.mmdb') as r:
    ///     r.lookup('89.160.20.129')
    pub fn __enter__(self: *Self) *Self {
        return self;
    }

    /// Closes the Reader when a context is exited.
    pub fn __exit__(self: *Self) bool {
        self.close();
        // Do not suppress exceptions.
        return false;
    }

    /// Closes the Reader to free all resources.
    pub fn close(self: *Self) void {
        if (!self.is_closed) {
            self.is_closed = true;
            self.db.close();
        }
    }

    /// Looks up a record by an IP address.
    pub fn lookup(self: *Self, ip_address: []const u8) ?*pyoz.PyObject {
        const ip = std.net.Address.parseIp(ip_address, 0) catch |err| {
            return pyoz.raiseValueError(@errorName(err));
        };

        const result = self.db.lookup(maxminddb.any.Value, allocator, ip, .{}) catch |err| {
            _module.getException(0).raise(@errorName(err));
            return null;
        };

        const r = result orelse return _module.toPy(?bool, null);
        defer r.deinit();

        return anyValueToPyObject(r.value);
    }
};

/// Converts any.Value we used to decode an MMDB record to a Python Object.
fn anyValueToPyObject(src: maxminddb.any.Value) ?*pyoz.PyObject {
    return switch (src) {
        .map => |entries| {
            const dict = pyoz.py.PyDict_New() orelse return null;

            for (entries) |entry| {
                const key_obj = _module.toPy([]const u8, entry.key) orelse {
                    pyoz.py.Py_DecRef(dict);
                    return null;
                };

                const value_obj = anyValueToPyObject(entry.value) orelse {
                    pyoz.py.Py_DecRef(key_obj);
                    pyoz.py.Py_DecRef(dict);
                    return null;
                };

                _ = pyoz.py.PyDict_SetItem(dict, key_obj, value_obj);

                pyoz.py.Py_DecRef(key_obj);
                pyoz.py.Py_DecRef(value_obj);
            }

            return dict;
        },
        .array => |items| {
            const list = pyoz.py.PyList_New(@intCast(items.len)) orelse return null;

            for (items, 0..) |item, i| {
                const item_obj = anyValueToPyObject(item) orelse {
                    pyoz.py.Py_DecRef(list);
                    return null;
                };

                _ = pyoz.py.PyList_SetItem(list, @intCast(i), item_obj);
            }

            return list;
        },
        .string => |v| _module.toPy([]const u8, v),
        .int32 => |v| _module.toPy(i32, v),
        .uint16 => |v| _module.toPy(u16, v),
        .uint32 => |v| _module.toPy(u32, v),
        .uint64 => |v| _module.toPy(u64, v),
        .uint128 => |v| _module.toPy(u128, v),
        .double => |v| _module.toPy(f64, v),
        .float => |v| _module.toPy(f32, v),
        .boolean => |v| _module.toPy(bool, v),
    };
}

pub const _module = pyoz.module(.{
    .name = "maxmind",
    .from = &.{@This()},
    .exceptions = &.{
        pyoz.exception("ReaderException", .Exception),
    },
});

// Required: forces analysis of all pub decls so PyInit_ is exported.
comptime {
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        _ = @field(@This(), decl.name);
    }
}
