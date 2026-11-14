import platform

from app import app


def test_health():
    body = app.test_client().get("/health").get_json()
    assert body["ok"] is True
    assert body["platform"].startswith("Linux")


def test_add():
    assert app.test_client().get("/add/2/3").get_json() == {"result": 5}
