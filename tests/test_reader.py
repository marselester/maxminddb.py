import maxmind
import pytest

TEST_DB = "test-data/test-data/GeoLite2-City-Test.mmdb"


@pytest.fixture(scope="session")
def db():
    db = maxmind.Reader(TEST_DB)
    yield db
    db.close()
    assert db.is_closed


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
    assert isinstance(r["city"], dict)
    assert isinstance(r["city"]["names"], dict)
    assert isinstance(r["location"]["latitude"], float)
    assert isinstance(r["location"]["longitude"], float)
    assert isinstance(r["subdivisions"], list)
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


def test_metadata(db):
    meta = db.metadata()
    assert meta["database_type"] == "GeoLite2-City"
    assert meta["ip_version"] == 6
    assert "en" in meta["languages"]
