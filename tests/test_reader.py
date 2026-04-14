import types

import maxmind
import pytest

TEST_DB = "test-data/test-data/GeoLite2-City-Test.mmdb"


@pytest.fixture(scope="session")
def db():
    db = maxmind.Reader(TEST_DB)
    yield db
    db.close()


def test_open_db_not_found():
    with pytest.raises(FileNotFoundError, match="FileNotFound"):
        maxmind.Reader("notfound.mmdb")


def test_open_db_corrupted():
    with pytest.raises(maxmind.ReaderException, match="CorruptedTree"):
        maxmind.Reader("test-data/test-data/GeoIP2-City-Test-Invalid-Node-Count.mmdb")


def test_open_db_context_manager():
    with maxmind.Reader(TEST_DB) as db:
        r, _ = db.lookup("89.160.20.128")
        assert r


def test_close_db_idempotent():
    db = maxmind.Reader(TEST_DB)
    r, _ = db.lookup("89.160.20.128")
    assert r
    db.close()
    db.close()


def test_lookup_record_found(db):
    r, net = db.lookup("89.160.20.128")
    assert r["city"]["names"]["en"] == "Linköping"
    assert r["country"]["names"]["en"] == "Sweden"
    assert net == "89.160.20.128/25"


def test_lookup_record_not_found(db):
    r, net = db.lookup("0.0.0.0")
    assert (r, net) == (None, None)


def test_lookup_invalid_ip(db):
    with pytest.raises(ValueError, match="InvalidIPAddressFormat"):
        db.lookup("123")


def test_lookup_only_fields(db):
    r, net = db.lookup("89.160.20.128", "city,continent")
    assert r["city"]["names"]["en"] == "Linköping"
    assert "country" not in r
    assert net == "89.160.20.128/25"


def test_lookup_nested_types(db):
    r, _ = db.lookup("89.160.20.128")
    assert isinstance(r["city"], types.MappingProxyType)
    assert isinstance(r["city"]["names"], types.MappingProxyType)
    assert isinstance(r["location"]["latitude"], float)
    assert isinstance(r["location"]["longitude"], float)
    assert isinstance(r["subdivisions"], tuple)
    assert len(r["subdivisions"]) > 0


def test_scan_record_found(db):
    records = list(db.scan("89.160.20.0/24"))
    assert len(records) == 2

    r, net = records[0]
    assert r["city"]["names"]["en"] == "Linköping"
    assert net == "89.160.20.112/28"

    r, net = records[1]
    assert r["city"]["names"]["en"] == "Linköping"
    assert net == "89.160.20.128/25"


def test_scan_only_fields(db):
    records = list(db.scan("89.160.20.0/24", "city,continent"))
    assert len(records) == 2

    for r, net in records:
        assert r["city"]["names"]["en"] == "Linköping"
        assert "country" not in r


def test_scan_invalid_network(db):
    with pytest.raises(ValueError, match="InvalidIPAddressFormat"):
        db.scan("123")


def test_scan_whole_db(db):
    count = sum(1 for _ in db)
    assert count == 242
    assert count == sum(1 for _ in db.scan())


def test_contains(db):
    assert "89.160.20.128" in db
    assert "0.0.0.0" not in db
    assert "invalid" not in db


def test_metadata(db):
    meta = db.metadata()
    assert meta["database_type"] == "GeoLite2-City"
    assert meta["ip_version"] == 6
    assert meta["binary_format_major_version"] == 2
    assert meta["binary_format_minor_version"] == 0
    assert meta["record_size"] == 28
    assert meta["node_count"] > 0
    assert meta["build_epoch"] > 0
    assert "en" in meta["languages"]


def test_query_lookup(db):
    q = db.query("city,continent")
    r, net = q.lookup("89.160.20.128")
    assert r["city"]["names"]["en"] == "Linköping"
    assert "country" not in r
    assert net == "89.160.20.128/25"


def test_query_lookup_not_found(db):
    q = db.query("city")
    r, net = q.lookup("0.0.0.0")
    assert (r, net) == (None, None)


def test_query_lookup_cached(db):
    q = db.query("city")
    r1, _ = q.lookup("89.160.20.128")
    r2, _ = q.lookup("89.160.20.128")
    assert r1["city"]["names"]["en"] == r2["city"]["names"]["en"]


def test_query_scan(db):
    q = db.query("city,continent")
    records = list(q.scan("89.160.20.0/24"))
    assert len(records) == 2
    for r, net in records:
        assert r["city"]["names"]["en"] == "Linköping"
        assert "country" not in r


def test_query_scan_whole_db(db):
    q = db.query("city")
    count = sum(1 for _ in q.scan())
    assert count == 242


def test_query_one_liner_scan(db):
    count = sum(1 for _ in db.query("city").scan())
    assert count == 242


def test_query_no_fields(db):
    """query() without args decodes all fields."""
    q = db.query()
    r, _ = q.lookup("89.160.20.128")
    assert "city" in r
    assert "country" in r
    assert "location" in r


def test_query_empty_fields(db):
    q = db.query("")
    r, _ = q.lookup("89.160.20.128")
    assert "city" in r
    assert "country" in r
    assert "location" in r


def test_query_too_many_fields(db):
    with pytest.raises(ValueError, match="TooManyFields"):
        db.query(
            "a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z,a1,b1,c1,d1,e1,f1,g1"
        )


def test_json_lookup(db):
    j = db.json("city")
    json_str, net = j.lookup("89.160.20.128")
    assert isinstance(json_str, str)
    assert '"Karlstad"' in json_str or '"Linköping"' in json_str
    assert net


def test_json_lookup_all_fields(db):
    j = db.json()
    json_str, net = j.lookup("89.160.20.128")
    assert '"city"' in json_str
    assert '"country"' in json_str


def test_json_lookup_not_found(db):
    j = db.json("city")
    json_str, net = j.lookup("0.0.0.0")
    assert (json_str, net) == (None, None)


def test_json_after_close():
    db = maxmind.Reader(TEST_DB)
    j = db.json("city")
    db.close()
    with pytest.raises(maxmind.ReaderException, match="ReaderClosed"):
        j.lookup("89.160.20.128")


def test_lookup_after_close():
    db = maxmind.Reader(TEST_DB)
    db.close()
    with pytest.raises(maxmind.ReaderException, match="ReaderClosed"):
        db.lookup("89.160.20.128")


def test_scan_after_close():
    db = maxmind.Reader(TEST_DB)
    db.close()
    with pytest.raises(maxmind.ReaderException, match="ReaderClosed"):
        db.scan()


def test_metadata_after_close():
    db = maxmind.Reader(TEST_DB)
    db.close()
    with pytest.raises(maxmind.ReaderException, match="ReaderClosed"):
        db.metadata()


def test_iter_after_close():
    db = maxmind.Reader(TEST_DB)
    db.close()
    with pytest.raises(maxmind.ReaderException, match="ReaderClosed"):
        iter(db)


def test_query_after_close():
    db = maxmind.Reader(TEST_DB)
    db.close()
    with pytest.raises(maxmind.ReaderException, match="ReaderClosed"):
        db.query("city")


def test_query_lookup_after_close():
    db = maxmind.Reader(TEST_DB)
    q = db.query("city")
    db.close()
    with pytest.raises(maxmind.ReaderException, match="ReaderClosed"):
        q.lookup("89.160.20.128")


def test_query_scan_after_close():
    db = maxmind.Reader(TEST_DB)
    q = db.query("city")
    db.close()
    with pytest.raises(maxmind.ReaderException, match="ReaderClosed"):
        list(q.scan())


def test_iterator_after_close():
    db = maxmind.Reader(TEST_DB)
    it = iter(db.scan())
    db.close()
    with pytest.raises(maxmind.ReaderException, match="ReaderClosed"):
        next(it)
