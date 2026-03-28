const std = @import("std");

const pyoz = @import("PyOZ");
const maxminddb = @import("maxminddb");

const allocator = std.heap.smp_allocator;

pub const Reader = struct {
    db: maxminddb.Reader,

    /// Opens a MaxMind DB file, for example:
    /// r = maxmind.Reader('GeoLite2-City.mmdb')
    pub fn __new__(path: []const u8) !Reader {
        return .{
            .db = try maxminddb.Reader.mmap(allocator, path, .{}),
        };
    }

    /// Closes a db when the Reader is deleted, for example:
    /// del r
    pub fn __del__(self: *Reader) void {
        self.db.close();
    }

    pub fn lookup(self: *Reader, ip_address: []const u8) ?*pyoz.PyObject {
        const ip = std.net.Address.parseIp(ip_address, 0) catch |err| {
            std.debug.print("address {any}", .{err});
            return null;
        };

        const r = self.db.lookup(maxminddb.any.Value, allocator, ip, .{}) catch |err| {
            std.debug.print("lookup {any}", .{err});
            return null;
        };
        if (r == null) {
            std.debug.print("not found", .{});
            return null;
        }
        defer r.?.deinit();

        std.debug.print("record {any}", .{r});

        return anyValueToPyObject(r.?.value);
    }
};

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
});

// Required: forces analysis of all pub decls so PyInit_ is exported.
comptime {
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        _ = @field(@This(), decl.name);
    }
}
