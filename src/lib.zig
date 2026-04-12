const std = @import("std");

const pyoz = @import("PyOZ");
const maxminddb = @import("maxminddb");

const allocator = std.heap.smp_allocator;
const Fields = maxminddb.Fields(32);

/// Reads MaxMind DB files.
pub const Reader = struct {
    is_closed: bool,
    _db: maxminddb.Reader,
    _lookup_cache: maxminddb.Cache(maxminddb.any.Value),
    _map_key_cache: MapKeyCache,
    _py_cache: PyDictCache = .{},

    const Self = @This();
    const all_ipv4 = "0.0.0.0/0";
    const all_ipv6 = "::/0";

    /// Opens a MaxMind DB file, for example:
    /// r = maxmind.Reader('GeoLite2-City.mmdb')
    pub fn __new__(path: []const u8) !Reader {
        // Release GIL during mmap and index building.
        const gil = pyoz.releaseGIL();
        const db_or_err = maxminddb.Reader.mmap(
            allocator,
            path,
            .{ .ipv4_index_first_n_bits = 16 },
        );
        gil.acquire();

        var db = db_or_err catch |err| {
            // Raise ReaderException for db format errors.
            // OS errors (FileNotFound, AccessDenied, etc.) are left for PyOZ
            // to map to Python's built-in exceptions.
            if (isMMDbError(err)) {
                _module.getException(0).raise(@errorName(err));
            }

            return err;
        };
        errdefer db.close();

        return .{
            ._db = db,
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
            self._py_cache.deinit();
            self._map_key_cache.deinit();
            self._lookup_cache.deinit();
            self._db.close();
        }
    }

    /// Returns db metadata.
    pub fn metadata(self: *Self) ?*pyoz.PyObject {
        if (self.is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const meta = maxminddb.Metadata.decodeAs(
            maxminddb.any.Value,
            arena.allocator(),
            self._db.src,
        ) catch |err| {
            _module.getException(0).raise(@errorName(err));
            return null;
        };

        return frozenValueToPyObject(meta, &self._map_key_cache);
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
        if (self.is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const ip = std.net.Address.parseIp(args.value.ip_address, 0) catch |err| {
            return pyoz.raiseValueError(@errorName(err));
        };

        if (args.value.fields) |fields_str| {
            // Decode only requested fields, no caching.
            const f = Fields.parse(fields_str, ',') catch |err| {
                return pyoz.raiseValueError(@errorName(err));
            };

            const result = self._db.lookup(
                maxminddb.any.Value,
                allocator,
                ip,
                .{ .only = f.only() },
            ) catch |err| {
                _module.getException(0).raise(@errorName(err));
                return null;
            };

            const r = result orelse return resultAsTuple(
                pyoz.py.Py_RETURN_NONE(),
                pyoz.py.Py_RETURN_NONE(),
            );
            defer r.deinit();

            const record_obj = frozenValueToPyObject(r.value, &self._map_key_cache) orelse {
                return null;
            };
            const network_obj = formatNetwork(r.network) orelse {
                pyoz.py.Py_DecRef(record_obj);
                return null;
            };

            return resultAsTuple(record_obj, network_obj);
        }

        return cachedLookup(
            &self._db,
            ip,
            .{},
            &self._py_cache,
            &self._lookup_cache,
            &self._map_key_cache,
        );
    }

    /// Scans networks within the given IP range (CIDR notation is also supported).
    /// When no network is given, scans the whole db.
    /// The iterator yields (record, network) tuples.
    /// The ValueError exception indicates that a network is invalid.
    /// The ReaderException is raised if a db read has failed.
    pub fn scan(
        self: *Self,
        args: pyoz.Args(struct {
            network: ?[]const u8 = null,
            fields: ?[]const u8 = null,
        }),
    ) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
        if (self.is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const network = args.value.network orelse
            if (self._db.metadata.ip_version == 6) all_ipv6 else all_ipv4;

        return createScanIterator(
            self,
            network,
            args.value.fields,
            &self._map_key_cache,
        );
    }

    /// Scans the whole db.
    pub fn __iter__(self: *Self) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
        return self.scan(.{ .value = .{} });
    }

    /// Returns a cached, field-filtered view of the database.
    /// Best for repeated lookups/scans with the same fields, e.g., used in web services.
    ///
    /// q = db.only("city,country")
    /// r, net = q.lookup(ip)
    ///
    /// for r, net in q.scan():
    ///     print(r, net)
    ///
    /// For free-threaded Python, use per-thread `only()` instances.
    pub fn only(self: *Self, fields_str: []const u8) !Only {
        if (self.is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return error.ReaderClosed;
        }

        var parsed_fields = try Fields.parseAlloc(allocator, fields_str, ',');
        errdefer parsed_fields.deinit(allocator);

        return .{
            .reader = self,
            .fields = parsed_fields,
            .cache = try maxminddb.Cache(maxminddb.any.Value).init(allocator, .{}),
        };
    }
};

/// A cached, field-filtered view of a Reader created by Reader.only("city,country").
/// Fields are parsed once and the view has its own caches,
/// so repeated lookups/scans benefit from both maxminddb.Cache and Python object caching.
pub const Only = struct {
    reader: *Reader,
    fields: Fields,
    cache: maxminddb.Cache(maxminddb.any.Value),
    map_key_cache: MapKeyCache = .{},
    py_cache: PyDictCache = .{},

    /// Looks up a record by an IP address using cached field-filtered decoding.
    pub fn lookup(self: *Only, ip_address: []const u8) ?*pyoz.PyObject {
        if (self.reader.is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const ip = std.net.Address.parseIp(ip_address, 0) catch |err| {
            return pyoz.raiseValueError(@errorName(err));
        };

        return cachedLookup(
            &self.reader._db,
            ip,
            .{ .only = self.fields.only() },
            &self.py_cache,
            &self.cache,
            &self.map_key_cache,
        );
    }

    /// Scans networks using cached field-filtered decoding.
    pub fn scan(
        self: *Only,
        args: pyoz.Args(struct {
            network: ?[]const u8 = null,
        }),
    ) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
        if (self.reader.is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const network = args.value.network orelse
            if (self.reader._db.metadata.ip_version == 6) Reader.all_ipv6 else Reader.all_ipv4;

        return createScanIterator(
            self.reader,
            network,
            self.fields.buf,
            &self.map_key_cache,
        );
    }

    pub fn __del__(self: *Only) void {
        self.py_cache.deinit();
        self.map_key_cache.deinit();
        self.cache.deinit();
        self.fields.deinit(allocator);
    }
};

const IteratorState = struct {
    reader: *Reader,
    it: maxminddb.EntryIterator,
    fields: Fields,
    cache: maxminddb.Cache(maxminddb.any.Value),
    map_key_cache: *MapKeyCache,
    py_cache: PyDictCache = .{},

    pub fn next(self: *IteratorState) ?*pyoz.PyObject {
        if (self.reader.is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const entry = self.it.next() catch |err| {
            _module.getException(0).raise(@errorName(err));
            return null;
        } orelse {
            return null; // null signals StopIteration.
        };

        const network_obj = formatNetwork(entry.network) orelse {
            return null;
        };

        // Python dict cache hit.
        if (self.py_cache.get(entry.pointer)) |cached_record| {
            pyoz.py.Py_IncRef(cached_record);

            return resultAsTuple(cached_record, network_obj);
        }

        // Decode via maxminddb.Cache, build frozen Python objects, and cache them.
        const value = self.cache.decode(
            &self.reader._db,
            entry,
            .{ .only = self.fields.only() },
        ) catch |err| {
            pyoz.py.Py_DecRef(network_obj);
            _module.getException(0).raise(@errorName(err));

            return null;
        };

        const record_obj = frozenValueToPyObject(value, self.map_key_cache) orelse {
            pyoz.py.Py_DecRef(network_obj);
            return null;
        };
        self.py_cache.put(entry.pointer, record_obj);

        return resultAsTuple(record_obj, network_obj);
    }

    pub fn deinit(self: *IteratorState) void {
        self.py_cache.deinit();
        self.cache.deinit();
        self.fields.deinit(allocator);
        allocator.destroy(self);
    }
};

fn cachedLookup(
    db: *maxminddb.Reader,
    ip: std.net.Address,
    decode_options: maxminddb.Reader.DecodeOptions,
    py_cache: *PyDictCache,
    cache: *maxminddb.Cache(maxminddb.any.Value),
    map_key_cache: *MapKeyCache,
) ?*pyoz.PyObject {
    const found = db.find(ip, .{}) catch |err| {
        _module.getException(0).raise(@errorName(err));
        return null;
    } orelse return resultAsTuple(
        pyoz.py.Py_RETURN_NONE(),
        pyoz.py.Py_RETURN_NONE(),
    );

    const network_obj = formatNetwork(found.network) orelse {
        return null;
    };

    if (py_cache.get(found.pointer)) |cached_record| {
        pyoz.py.Py_IncRef(cached_record);
        return resultAsTuple(cached_record, network_obj);
    }

    const value = cache.decode(db, found, decode_options) catch |err| {
        pyoz.py.Py_DecRef(network_obj);
        _module.getException(0).raise(@errorName(err));
        return null;
    };

    const record_obj = frozenValueToPyObject(value, map_key_cache) orelse {
        pyoz.py.Py_DecRef(network_obj);
        return null;
    };
    py_cache.put(found.pointer, record_obj);

    return resultAsTuple(record_obj, network_obj);
}

fn createScanIterator(
    reader: *Reader,
    network: []const u8,
    fields: ?[]const u8,
    map_key_cache: *MapKeyCache,
) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
    const net = maxminddb.Network.parse(network) catch |err| {
        return pyoz.raiseValueError(@errorName(err));
    };

    const state = allocator.create(IteratorState) catch |err| {
        _module.getException(0).raise(@errorName(err));
        return null;
    };

    state.reader = reader;
    state.map_key_cache = map_key_cache;
    state.py_cache = .{};

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

    state.it = reader._db.entries(net, .{}) catch |err| {
        state.cache.deinit();
        state.fields.deinit(allocator);
        allocator.destroy(state);

        _module.getException(0).raise(@errorName(err));
        return null;
    };

    return .{ .state = state };
}

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

/// Caches frozen Python record objects (mappingproxy + tuples) keyed by MMDB data pointer.
/// Adjacent networks often share the same record (same data pointer),
/// so caching the Python object tree avoids rebuilding ~50 objects per cache hit.
///
/// Dicts are wrapped in PyDictProxy (read-only) and arrays in tuples
/// so cached objects can be safely returned to multiple callers.
/// It works alongside MapKeyCache (caches individual key strings) and
/// the maxminddb.Cache (caches decoded any.Value to skip binary decoding).
const PyDictCache = struct {
    entries: [cache_size]Entry = [_]Entry{.{}} ** cache_size,

    const cache_size = 16;
    const Entry = struct {
        pointer: usize = 0,
        obj: ?*pyoz.py.PyObject = null,
    };

    fn get(self: *PyDictCache, pointer: usize) ?*pyoz.py.PyObject {
        const slot = pointer & (cache_size - 1);
        const e = &self.entries[slot];

        // Cache hit.
        if (e.obj != null and e.pointer == pointer) {
            return e.obj.?;
        }

        return null;
    }

    fn put(self: *PyDictCache, pointer: usize, obj: *pyoz.py.PyObject) void {
        const slot = pointer & (cache_size - 1);
        const e = &self.entries[slot];

        if (e.obj) |old| {
            pyoz.py.Py_DecRef(old);
        }

        pyoz.py.Py_IncRef(obj);
        e.* = .{
            .pointer = pointer,
            .obj = obj,
        };
    }

    fn deinit(self: *PyDictCache) void {
        for (&self.entries) |*e| {
            if (e.obj) |obj| {
                pyoz.py.Py_DecRef(obj);
                e.obj = null;
            }
        }
    }
};

/// Converts any.Value to an immutable Python object tree.
/// Dicts become mappingproxy (read-only view via PyDictProxy_New) and
/// arrays become tuples so the result can be cached and shared safely.
fn frozenValueToPyObject(src: maxminddb.any.Value, cache: *MapKeyCache) ?*pyoz.PyObject {
    return switch (src) {
        .map => |entries| {
            const dict = pyoz.py.PyDict_New() orelse return null;

            for (entries) |entry| {
                const key_obj = cache.intern(entry.key) orelse {
                    pyoz.py.Py_DecRef(dict);
                    return null;
                };

                const value_obj = frozenValueToPyObject(entry.value, cache) orelse {
                    pyoz.py.Py_DecRef(key_obj);
                    pyoz.py.Py_DecRef(dict);
                    return null;
                };

                _ = pyoz.py.PyDict_SetItem(dict, key_obj, value_obj);

                pyoz.py.Py_DecRef(key_obj);
                pyoz.py.Py_DecRef(value_obj);
            }

            // Wrap in read-only proxy.
            const proxy: ?*pyoz.py.PyObject = pyoz.py.c.PyDictProxy_New(dict);
            pyoz.py.Py_DecRef(dict);

            return proxy;
        },
        .array => |items| {
            const tuple = pyoz.py.PyTuple_New(@intCast(items.len)) orelse return null;

            for (items, 0..) |item, i| {
                const item_obj = frozenValueToPyObject(item, cache) orelse {
                    pyoz.py.Py_DecRef(tuple);
                    return null;
                };

                _ = pyoz.py.PyTuple_SetItem(tuple, @intCast(i), item_obj);
            }

            return tuple;
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

fn formatNetwork(network: maxminddb.Network) ?*pyoz.PyObject {
    var net_buf: [64]u8 = undefined;
    const net_str = std.fmt.bufPrint(&net_buf, "{f}", .{network}) catch |err| {
        _module.getException(0).raise(@errorName(err));
        return null;
    };

    return _module.toPy([]const u8, net_str);
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
