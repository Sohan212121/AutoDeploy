import json
from pathlib import Path
import pytest
from app.app import create_app


def test_app_starts_and_creates_without_error():
    """1. App starts and creates without error."""
    app = create_app()
    assert app is not None
    assert app.config["APP_NAME"] == "AutoDeploy"
    assert app.config["APP_VERSION"] == "1.0.0"

    # Test with custom config overrides
    custom_app = create_app({
        "APP_NAME": "AutoDeployCustom",
        "APP_VERSION": "2.0.0",
    })
    assert custom_app.config["APP_NAME"] == "AutoDeployCustom"
    assert custom_app.config["APP_VERSION"] == "2.0.0"


def test_home_page_returns_200_and_contains_name_and_version(client):
    """2. GET / returns 200 and contains 'AutoDeploy' and the test version."""
    response = client.get("/")
    assert response.status_code == 200
    html = response.get_data(as_text=True)
    assert "AutoDeploy" in html
    assert "9.9.9-test" in html
    assert "abc1234" in html


def test_health_endpoint_returns_200_and_json(client):
    """3. GET /health returns 200, JSON status 'healthy', correct version."""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.is_json
    data = response.get_json()
    assert data["status"] == "healthy"
    assert data["application"] == "AutoDeploy"
    assert data["version"] == "9.9.9-test"


def test_version_endpoint_dynamic_values(client):
    """4. GET /version returns the commit SHA and version from config (dynamic values)."""
    response = client.get("/version")
    assert response.status_code == 200
    assert response.is_json
    data = response.get_json()
    assert data["application"] == "AutoDeploy"
    assert data["version"] == "9.9.9-test"
    assert data["commit_sha"] == "abc1234def"
    assert "build_time" in data
    assert "environment" in data

    # Verify dynamically overridden values on a separate instance
    dynamic_app = create_app({
        "APP_NAME": "AutoDeployDynamic",
        "APP_VERSION": "3.2.1-custom",
        "GIT_COMMIT_SHA": "feebda9876",
        "BUILD_TIME": "2026-11-10T14:00:00Z",
        "DEPLOY_ENV": "staging",
    })
    with dynamic_app.test_client() as dyn_client:
        dyn_response = dyn_client.get("/version")
        assert dyn_response.status_code == 200
        dyn_data = dyn_response.get_json()
        assert dyn_data["application"] == "AutoDeployDynamic"
        assert dyn_data["version"] == "3.2.1-custom"
        assert dyn_data["commit_sha"] == "feebda9876"
        assert dyn_data["build_time"] == "2026-11-10T14:00:00Z"
        assert dyn_data["environment"] == "staging"


def test_unknown_route_returns_404_json(client):
    """5. Unknown route returns 404 JSON."""
    response = client.get("/route/does/not/exist")
    assert response.status_code == 404
    assert response.is_json
    assert response.get_json() == {"error": "not found"}


def test_home_page_shows_last_deployment_status(client, history_file):
    """6. Home page shows the last deployment status when a valid history file exists."""
    records = [
        {
            "deployment_id": "dep-001",
            "commit_sha": "prev123",
            "image_tag": "autodeploy:1.0.0",
            "timestamp": "2026-11-10T08:00:00Z",
            "status": "failed",
            "environment": "staging",
            "error": "Timeout connecting to registry",
        },
        {
            "deployment_id": "dep-002",
            "commit_sha": "abc1234",
            "image_tag": "autodeploy:1.0.1",
            "timestamp": "2026-11-10T14:30:00Z",
            "status": "deployed_successfully",
            "environment": "production",
            "error": None,
        },
    ]
    history_file.write_text(json.dumps(records), encoding="utf-8")

    response = client.get("/")
    assert response.status_code == 200
    html = response.get_data(as_text=True)
    assert "deployed_successfully" in html
    assert "2026-11-10T14:30:00Z" in html


def test_home_page_does_not_crash_when_history_file_missing_or_invalid(client, history_file):
    """7. Home page does not crash when the history file is missing, empty, or contains invalid JSON."""
    # 7a: File does not exist
    if history_file.exists():
        history_file.unlink()
    response_missing = client.get("/")
    assert response_missing.status_code == 200
    assert "No deployment history yet" in response_missing.get_data(as_text=True)

    # 7b: File exists but is empty
    history_file.write_text("", encoding="utf-8")
    response_empty = client.get("/")
    assert response_empty.status_code == 200
    assert "No deployment history yet" in response_empty.get_data(as_text=True)

    # 7c: File contains invalid JSON
    history_file.write_text("{corrupt_json: [invalid,", encoding="utf-8")
    response_invalid = client.get("/")
    assert response_invalid.status_code == 200
    assert "No deployment history yet" in response_invalid.get_data(as_text=True)

    # 7d: File contains valid JSON but not a non-empty list
    history_file.write_text("[]", encoding="utf-8")
    response_empty_list = client.get("/")
    assert response_empty_list.status_code == 200
    assert "No deployment history yet" in response_empty_list.get_data(as_text=True)

