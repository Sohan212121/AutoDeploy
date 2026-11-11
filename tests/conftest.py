import pytest
from app.app import create_app


@pytest.fixture
def history_file(tmp_path):
    """Temporary file path for deployment history testing."""
    return tmp_path / "deployment_history.json"


@pytest.fixture
def client(tmp_path, history_file):
    """Client fixture using create_app with test configuration overrides."""
    app = create_app({
        "TESTING": True,
        "APP_VERSION": "9.9.9-test",
        "GIT_COMMIT_SHA": "abc1234def",
        "DEPLOY_HISTORY_FILE": str(history_file),
    })
    with app.test_client() as test_client:
        yield test_client

