const std = @import("std");

const pyoz = @import("PyOZ");
const maxminddb = @import("maxminddb");

const Fields = maxminddb.Fields(32);

/// Reads MaxMind DB files.
pub const Reader = struct {
    is_closed: bool,
    _db: maxminddb.Reader,
    _lookup_cache: maxminddb.Cache(maxminddb.any.Value),
    _map_key_cache: MapKeyCache,
    _allocator: std.mem.Allocator = std.heap.smp_allocator,

    const Self = @This();
    const all_ipv4 = "0.0.0.0/0";
    const all_ipv6 = "::/0";

    /// Opens a MaxMind DB file, for example:
    /// r = maxmind.Reader('GeoLite2-City.mmdb')
    pub fn __new__(path: []const u8) !Reader {
        const allocator = std.heap.smp_allocator;

        return .{
            ._db = maxminddb.Reader.mmap(
                allocator,
                path,
                .{ .ipv4_index_first_n_bits = 16 },
            ) catch |err| {
                // Raise ReaderException for db format errors.
                // OS errors (FileNotFound, AccessDenied, etc.) are left for PyOZ
                // to map to Python's built-in exceptions.
                if (isMMDbError(err)) {
                    _module.getException(0).raise(@errorName(err));
                }

                return err;
            },
            ._lookup_cache = try maxminddb.Cache(maxminddb.any.Value).init(allocator, .{}),
            ._map_key_cache = .{},
            .is_closed = false,
        };
    }

    fn isMMDbError(err: anyerror) bool {
        inline for (@typeInfo(maxminddb.Error).error_set.?) |e| {
            if (err == @field(anyerror, e.name)) return true;
        }
        return false;
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
            self._map_key_cache.deinit();
            self._lookup_cache.deinit();
            self._db.close();
        }
    }

    /// Returns db metadata.
    pub fn metadata(self: *Self) ?*pyoz.PyObject {
        var arena = std.heap.ArenaAllocator.init(self._allocator);
        defer arena.deinit();

        const meta = maxminddb.Reader.decodeMetadata(
            maxminddb.any.Value,
            arena.allocator(),
            self._db.src,
        ) catch |err| {
            _module.getException(0).raise(@errorName(err));
            return null;
        };

        return anyValueToPyObject(meta, &self._map_key_cache);
    }

    /// Looks up a record by an IP address.
    /// The returned value is a tuple (record, network) when it's found and (None, None) otherwise.
    /// The ValueError exception indicates that an IP address is invalid.
    /// The ReaderException is raised if a db read has failed.
    pub fn lookup(
        self: *Self,
        args: pyoz.Args(struct {
            ip_address: []const u8,
            fields: ?[]const u8 = null,
        }),
    ) ?*pyoz.PyObject {
        const ip = std.net.Address.parseIp(args.value.ip_address, 0) catch |err| {
            return pyoz.raiseValueError(@errorName(err));
        };

        // Bypass the cache when only given fields need to be decoded from the db.
        var result: ?maxminddb.Result(maxminddb.any.Value) = null;
        if (args.value.fields) |only| {
            const f = Fields.parse(only, ',') catch |err| {
                return pyoz.raiseValueError(@errorName(err));
            };

            result = self._db.lookup(
                maxminddb.any.Value,
                self._allocator,
                ip,
                .{ .only = f.only() },
            ) catch |err| {
                _module.getException(0).raise(@errorName(err));
                return null;
            };
        } else {
            result = self._db.lookupWithCache(
                maxminddb.any.Value,
                &self._lookup_cache,
                ip,
                .{},
            ) catch |err| {
                _module.getException(0).raise(@errorName(err));
                return null;
            };
        }

        const r = result orelse return resultAsTuple(
            pyoz.py.Py_RETURN_NONE(),
            pyoz.py.Py_RETURN_NONE(),
        );
        defer r.deinit();

        return recordAsTuple(r, &self._map_key_cache);
    }

    /// Scans networks within the given IP range (CIDR notation is also supported).
    /// The iterator yields (record, network) tuples.
    /// The ValueError exception indicates that a network is invalid.
    /// The ReaderException is raised if a db read has failed.
    pub fn scan(
        self: *Self,
        args: pyoz.Args(struct {
            network: []const u8,
            fields: ?[]const u8 = null,
        }),
    ) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
        return self._scan(args.value.network, args.value.fields);
    }

    /// Scans the whole db.
    pub fn __iter__(self: *Self) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
        const network = if (self._db.metadata.ip_version == 6) all_ipv6 else all_ipv4;
        return self._scan(network, null);
    }

    fn _scan(
        self: *Self,
        network: []const u8,
        fields: ?[]const u8,
    ) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
        const net = maxminddb.Network.parse(network) catch |err| {
            return pyoz.raiseValueError(@errorName(err));
        };

        const allocator = self._allocator;

        // Heap-allocate the iterator so all internal pointers remain stable.
        // PyOZ copies only the pointer, not the struct.
        const state = allocator.create(IteratorState) catch |err| {
            _module.getException(0).raise(@errorName(err));
            return null;
        };

        state.allocator = allocator;
        state.map_key_cache = &self._map_key_cache;

        state.fields = if (fields) |fields_str|
            Fields.parseAlloc(allocator, fields_str, ',') catch |err| {
                allocator.destroy(state);
                return pyoz.raiseValueError(@errorName(err));
            }
        else
            .{};

        state.cache = maxminddb.Cache(maxminddb.any.Value).init(allocator, .{}) catch |err| {
            state.fields.deinit(allocator);
            allocator.destroy(state);

            _module.getException(0).raise(@errorName(err));
            return null;
        };

        state.it = self._db.scanWithCache(
            maxminddb.any.Value,
            &state.cache,
            net,
            .{ .only = state.fields.only() },
        ) catch |err| {
            state.cache.deinit();
            state.fields.deinit(allocator);
            allocator.destroy(state);

            _module.getException(0).raise(@errorName(err));
            return null;
        };

        return .{
            .state = state,
        };
    }
};

const IteratorState = struct {
    it: maxminddb.Iterator(maxminddb.any.Value),
    fields: Fields,
    cache: maxminddb.Cache(maxminddb.any.Value),
    map_key_cache: *MapKeyCache,
    allocator: std.mem.Allocator,

    pub fn next(self: *IteratorState) ?*pyoz.PyObject {
        const item = self.it.next() catch |err| {
            _module.getException(0).raise(@errorName(err));
            return null;
        };

        // null signals StopIteration.
        const r = item orelse return null;

        return recordAsTuple(r, self.map_key_cache);
    }

    pub fn deinit(self: *IteratorState) void {
        self.cache.deinit();
        self.fields.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Caches MMDB record keys, i.e., Python string objects for "city", "country", "en", etc.
const MapKeyCache = struct {
    entries: [cache_size]Entry = [_]Entry{.{}} ** cache_size,

    const cache_size = 256;
    const Entry = struct {
        key_addr: usize = 0,
        obj: ?*pyoz.py.PyObject = null,
    };

    /// Returns a cached interned Python string for the given map key,
    /// or creates, interns, and caches a new one.
    fn intern(self: *MapKeyCache, key: []const u8) ?*pyoz.py.PyObject {
        // MMDB keys point into mmap'd data where identical keys share the same address,
        // so the pointer alone identifies the key.
        // Mask the address to fit into 0..cache_size range.
        // Masking is similar to "address % cache_size", but cache_size must be a power of 2.
        const slot = @intFromPtr(key.ptr) & (cache_size - 1);
        const e = &self.entries[slot];

        // Cache hit.
        if (e.obj != null and e.key_addr == @intFromPtr(key.ptr)) {
            pyoz.py.Py_IncRef(e.obj.?);
            return e.obj.?;
        }

        // Cache miss: create a new Python string and intern it.
        // Interning deduplicates strings so dict key lookups use pointer
        // comparison instead of string comparison.
        // The obj must be a variable here because InternInPlace may replace
        // the pointer with an already-interned string.
        var obj = _module.toPy([]const u8, key) orelse return null;
        pyoz.py.c.PyUnicode_InternInPlace(@ptrCast(&obj));

        // Drop the cache's reference to the old object if this slot was occupied.
        if (e.obj) |old| {
            pyoz.py.Py_DecRef(old);
        }

        // Store the new object in the cache.
        // IncRef because two owners now hold a reference: the cache and the caller.
        pyoz.py.Py_IncRef(obj);
        e.* = .{
            .key_addr = @intFromPtr(key.ptr),
            .obj = obj,
        };

        return obj;
    }

    fn deinit(self: *MapKeyCache) void {
        for (&self.entries) |*e| {
            if (e.obj) |obj| {
                pyoz.py.Py_DecRef(obj);
                e.obj = null;
            }
        }
    }
};

fn recordAsTuple(
    r: maxminddb.Result(maxminddb.any.Value),
    cache: *MapKeyCache,
) ?*pyoz.PyObject {
    var net_buf: [64]u8 = undefined;
    const net_str = std.fmt.bufPrint(&net_buf, "{f}", .{r.network}) catch |err| {
        _module.getException(0).raise(@errorName(err));
        return null;
    };

    const network_obj = _module.toPy([]const u8, net_str) orelse {
        return null;
    };
    const record_obj = anyValueToPyObject(r.value, cache) orelse {
        pyoz.py.Py_DecRef(network_obj);
        return null;
    };

    return resultAsTuple(record_obj, network_obj);
}

/// Converts any.Value we used to decode an MMDB record to a Python Object.
fn anyValueToPyObject(src: maxminddb.any.Value, cache: *MapKeyCache) ?*pyoz.PyObject {
    return switch (src) {
        .map => |entries| {
            const dict = pyoz.py.PyDict_New() orelse return null;

            for (entries) |entry| {
                const key_obj = cache.intern(entry.key) orelse {
                    pyoz.py.Py_DecRef(dict);
                    return null;
                };

                const value_obj = anyValueToPyObject(entry.value, cache) orelse {
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
                const item_obj = anyValueToPyObject(item, cache) orelse {
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

fn resultAsTuple(record: *pyoz.PyObject, network: *pyoz.PyObject) ?*pyoz.PyObject {
    const tuple = pyoz.py.PyTuple_New(2) orelse {
        pyoz.py.Py_DecRef(record);
        pyoz.py.Py_DecRef(network);
        return null;
    };

    _ = pyoz.py.PyTuple_SetItem(tuple, 0, record);
    _ = pyoz.py.PyTuple_SetItem(tuple, 1, network);

    return tuple;
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
