const std = @import("std");

const pyoz = @import("PyOZ");
const maxminddb = @import("maxminddb");

const allocator = std.heap.smp_allocator;
const Fields = maxminddb.Fields(32);

/// Reads MaxMind DB files.
pub const Reader = struct {
    _is_closed: bool,
    _db: maxminddb.Reader,

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

        const db = db_or_err catch |err| {
            // Raise ReaderException for db format errors.
            // OS errors (FileNotFound, AccessDenied, etc.) are left for PyOZ
            // to map to Python's built-in exceptions.
            if (isMMDbError(err)) {
                _module.getException(0).raise(@errorName(err));
            }

            return err;
        };

        return .{
            ._db = db,
            ._is_closed = false,
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
        if (!self._is_closed) {
            self._is_closed = true;
            self._db.close();
        }
    }

    /// Returns db metadata.
    pub fn metadata(self: *Self) ?*pyoz.PyObject {
        if (self._is_closed) {
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

        return frozenValueToPyObject(meta, null);
    }

    /// Checks if an IP address has a record in the database:
    /// "1.2.3.4" in db
    pub fn __contains__(self: *const Self, ip_address: []const u8) bool {
        if (self._is_closed) {
            return false;
        }

        const ip = std.net.Address.parseIp(ip_address, 0) catch return false;
        const entry = @constCast(&self._db).find(ip, .{}) catch return false;

        return entry != null;
    }

    /// Looks up a record by an IP address.
    /// Returns a tuple (record, network) when found and (None, None) otherwise.
    /// ValueError is raised when the IP address is invalid.
    /// ReaderException is raised when db reading fails.
    ///
    /// Use db.query() for repeated lookups for better performance.
    pub fn lookup(
        self: *Self,
        args: pyoz.Args(struct {
            ip_address: []const u8,
            fields: ?[]const u8 = null,
        }),
    ) ?*pyoz.PyObject {
        if (self._is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const ip = std.net.Address.parseIp(args.value.ip_address, 0) catch |err| {
            return pyoz.raiseValueError(@errorName(err));
        };

        const parsed_fields = if (args.value.fields) |fields_str|
            Fields.parse(fields_str, ',') catch |err| {
                return pyoz.raiseValueError(@errorName(err));
            }
        else
            Fields{};

        const result = self._db.lookup(
            maxminddb.any.Value,
            allocator,
            ip,
            .{ .only = parsed_fields.only() },
        ) catch |err| {
            _module.getException(0).raise(@errorName(err));
            return null;
        };

        const r = result orelse return resultAsTuple(
            pyoz.py.Py_RETURN_NONE(),
            pyoz.py.Py_RETURN_NONE(),
        );
        defer r.deinit();

        const record_obj = frozenValueToPyObject(r.value, null) orelse {
            return null;
        };
        const network_obj = formatNetwork(r.network) orelse {
            pyoz.py.Py_DecRef(record_obj);
            return null;
        };

        return resultAsTuple(record_obj, network_obj);
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
        if (self._is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const network = args.value.network orelse
            if (self._db.metadata.ip_version == 6) all_ipv6 else all_ipv4;

        return createScanIterator(
            self,
            network,
            args.value.fields,
        );
    }

    /// Scans the whole db.
    pub fn __iter__(self: *Self) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
        return self.scan(.{ .value = .{} });
    }

    /// Returns a cached view of the database, optionally filtered to specific fields.
    /// Best for repeated lookups/scans, e.g., in web services.
    ///
    /// q = db.query("city,country")
    /// r, net = q.lookup(ip)
    ///
    /// for r, net in q.scan():
    ///     print(r, net)
    ///
    /// For free-threaded Python, use per-thread `query()` instances.
    pub fn query(
        self: *Self,
        args: pyoz.Args(struct {
            fields: ?[]const u8 = null,
        }),
    ) !Query {
        if (self._is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return error.ReaderClosed;
        }

        var parsed_fields = if (args.value.fields) |s|
            Fields.parseAlloc(allocator, s, ',') catch |err| {
                _ = pyoz.raiseValueError(@errorName(err));
                return err;
            }
        else
            Fields{};
        errdefer parsed_fields.deinit(allocator);

        var q = Query{
            ._reader = self,
            ._fields = parsed_fields,
            ._cache = try maxminddb.Cache(maxminddb.any.Value).init(allocator, .{}),
        };
        q._reader_ref.set(_module.selfObject(Reader, self));

        return q;
    }

    /// Like query() but returns JSON strings instead of Python dicts.
    ///
    /// j = db.json("city,country")
    /// r, net = j.lookup(ip)
    pub fn json(
        self: *Self,
        args: pyoz.Args(struct {
            fields: ?[]const u8 = null,
        }),
    ) !JSONQuery {
        if (self._is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return error.ReaderClosed;
        }

        var parsed_fields = if (args.value.fields) |s|
            Fields.parseAlloc(allocator, s, ',') catch |err| {
                _ = pyoz.raiseValueError(@errorName(err));
                return err;
            }
        else
            Fields{};
        errdefer parsed_fields.deinit(allocator);

        var jq = JSONQuery{
            ._reader = self,
            ._fields = parsed_fields,
            ._cache = try maxminddb.Cache(maxminddb.any.Value).init(allocator, .{}),
        };
        jq._reader_ref.set(_module.selfObject(Reader, self));

        return jq;
    }
};

/// A cached view of a Reader created by Reader.query().
/// Fields are parsed once and the view has its own caches,
/// so repeated lookups/scans benefit from both maxminddb.Cache and Python object caching.
pub const Query = struct {
    _reader: *Reader,
    // Prevent Reader from being GC'd while this Query is alive.
    // PyOZ auto-calls clear() on Ref fields during deallocation.
    _reader_ref: pyoz.Ref(Reader) = .{},
    _fields: Fields,
    _cache: maxminddb.Cache(maxminddb.any.Value),
    _map_key_cache: MapKeyCache = .{},
    _py_cache: PyDictCache = .{},

    /// Looks up a record by an IP address using cached decoding.
    pub fn lookup(self: *Query, ip_address: []const u8) ?*pyoz.PyObject {
        if (self._reader._is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const ip = std.net.Address.parseIp(ip_address, 0) catch |err| {
            return pyoz.raiseValueError(@errorName(err));
        };

        const entry = self._reader._db.find(ip, .{}) catch |err| {
            _module.getException(0).raise(@errorName(err));
            return null;
        } orelse return resultAsTuple(
            pyoz.py.Py_RETURN_NONE(),
            pyoz.py.Py_RETURN_NONE(),
        );

        const network_obj = formatNetwork(entry.network) orelse return null;

        if (self._py_cache.get(entry.pointer)) |cached_record| {
            pyoz.py.Py_IncRef(cached_record);
            return resultAsTuple(cached_record, network_obj);
        }

        const value = self._cache.decode(
            &self._reader._db,
            entry,
            .{ .only = self._fields.only() },
        ) catch |err| {
            pyoz.py.Py_DecRef(network_obj);
            _module.getException(0).raise(@errorName(err));
            return null;
        };

        const record_obj = frozenValueToPyObject(value, &self._map_key_cache) orelse {
            pyoz.py.Py_DecRef(network_obj);
            return null;
        };
        self._py_cache.put(entry.pointer, record_obj);

        return resultAsTuple(record_obj, network_obj);
    }

    /// Scans networks using cached decoding.
    pub fn scan(
        self: *Query,
        args: pyoz.Args(struct {
            network: ?[]const u8 = null,
        }),
    ) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
        if (self._reader._is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const network = args.value.network orelse
            if (self._reader._db.metadata.ip_version == 6) Reader.all_ipv6 else Reader.all_ipv4;

        return createScanIterator(
            self._reader,
            network,
            self._fields.buf,
        );
    }

    pub fn __del__(self: *Query) void {
        self._py_cache.deinit();
        self._map_key_cache.deinit();
        self._cache.deinit();
        self._fields.deinit(allocator);
    }
};

/// Like Query but returns JSON strings instead of Python dicts.
/// Skips building lots of Python objects per record.
pub const JSONQuery = struct {
    _reader: *Reader,
    _reader_ref: pyoz.Ref(Reader) = .{},
    _fields: Fields,
    _cache: maxminddb.Cache(maxminddb.any.Value),
    _json_cache: PyDictCache = .{},
    _arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(allocator),

    // 4KB covers most records.
    const json_buf_size = 4096;

    /// Looks up a record and returns (json_str, network) or (None, None).
    pub fn lookup(self: *JSONQuery, ip_address: []const u8) ?*pyoz.PyObject {
        if (self._reader._is_closed) {
            _module.getException(0).raise("ReaderClosed");
            return null;
        }

        const ip = std.net.Address.parseIp(ip_address, 0) catch |err| {
            return pyoz.raiseValueError(@errorName(err));
        };

        const entry = self._reader._db.find(ip, .{}) catch |err| {
            _module.getException(0).raise(@errorName(err));
            return null;
        } orelse return resultAsTuple(
            pyoz.py.Py_RETURN_NONE(),
            pyoz.py.Py_RETURN_NONE(),
        );

        const network_obj = formatNetwork(entry.network) orelse return null;

        // JSON string cache hit.
        if (self._json_cache.get(entry.pointer)) |cached_json| {
            pyoz.py.Py_IncRef(cached_json);
            return resultAsTuple(cached_json, network_obj);
        }

        const value = self._cache.decode(
            &self._reader._db,
            entry,
            .{ .only = self._fields.only() },
        ) catch |err| {
            pyoz.py.Py_DecRef(network_obj);
            _module.getException(0).raise(@errorName(err));
            return null;
        };

        const json_obj = self.formatJSON(value) orelse {
            pyoz.py.Py_DecRef(network_obj);
            return null;
        };
        self._json_cache.put(entry.pointer, json_obj);

        return resultAsTuple(json_obj, network_obj);
    }

    /// Formats any.Value as a JSON Python string using a stack buffer with arena fallback.
    fn formatJSON(self: *JSONQuery, value: maxminddb.any.Value) ?*pyoz.PyObject {
        var buf: [json_buf_size]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);

        if (value.format(&w)) {
            return _module.toPy([]const u8, w.buffer[0..w.end]);
        } else |_| {
            var list: std.ArrayListUnmanaged(u8) = .{};
            value.format(list.writer(self._arena.allocator())) catch |err| {
                _module.getException(0).raise(@errorName(err));
                return null;
            };

            const result = _module.toPy([]const u8, list.items);
            _ = self._arena.reset(.retain_capacity);

            return result;
        }
    }

    pub fn __del__(self: *JSONQuery) void {
        self._json_cache.deinit();
        self._cache.deinit();
        self._fields.deinit(allocator);
        self._arena.deinit();
    }
};

const IteratorState = struct {
    reader: *Reader,
    // IncRef'd to prevent Reader from being GC'd while iterating.
    reader_obj: *pyoz.py.PyObject,
    it: maxminddb.EntryIterator,
    fields: Fields,
    cache: maxminddb.Cache(maxminddb.any.Value),
    map_key_cache: MapKeyCache,
    py_cache: PyDictCache = .{},

    pub fn next(self: *IteratorState) ?*pyoz.PyObject {
        if (self.reader._is_closed) {
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

        const record_obj = frozenValueToPyObject(value, &self.map_key_cache) orelse {
            pyoz.py.Py_DecRef(network_obj);
            return null;
        };
        self.py_cache.put(entry.pointer, record_obj);

        return resultAsTuple(record_obj, network_obj);
    }

    pub fn deinit(self: *IteratorState) void {
        self.py_cache.deinit();
        self.map_key_cache.deinit();
        self.cache.deinit();
        self.fields.deinit(allocator);
        pyoz.py.Py_DecRef(self.reader_obj);
        allocator.destroy(self);
    }
};

fn createScanIterator(
    reader: *Reader,
    network: []const u8,
    fields: ?[]const u8,
) ?pyoz.LazyIterator(?*pyoz.PyObject, *IteratorState) {
    const net = maxminddb.Network.parse(network) catch |err| {
        return pyoz.raiseValueError(@errorName(err));
    };

    const state = allocator.create(IteratorState) catch |err| {
        _module.getException(0).raise(@errorName(err));
        return null;
    };

    const reader_obj = _module.selfObject(Reader, reader);
    pyoz.py.Py_IncRef(reader_obj);

    state.reader = reader;
    state.reader_obj = reader_obj;
    state.map_key_cache = .{};
    state.py_cache = .{};

    state.fields = if (fields) |fields_str|
        Fields.parseAlloc(allocator, fields_str, ',') catch |err| {
            pyoz.py.Py_DecRef(reader_obj);
            allocator.destroy(state);
            return pyoz.raiseValueError(@errorName(err));
        }
    else
        .{};

    state.cache = maxminddb.Cache(maxminddb.any.Value).init(allocator, .{}) catch |err| {
        state.fields.deinit(allocator);
        pyoz.py.Py_DecRef(reader_obj);
        allocator.destroy(state);
        _module.getException(0).raise(@errorName(err));
        return null;
    };

    state.it = reader._db.entries(net, .{}) catch |err| {
        state.cache.deinit();
        state.fields.deinit(allocator);
        pyoz.py.Py_DecRef(reader_obj);
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

    const cache_size = 64;
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
fn frozenValueToPyObject(src: maxminddb.any.Value, cache: ?*MapKeyCache) ?*pyoz.PyObject {
    return switch (src) {
        .map => |entries| {
            const dict = pyoz.py.PyDict_New() orelse return null;

            for (entries) |entry| {
                const key_obj = (if (cache) |c|
                    c.intern(entry.key)
                else
                    _module.toPy([]const u8, entry.key)) orelse {
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
