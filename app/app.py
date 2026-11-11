import json
from pathlib import Path
from flask import Flask, current_app, jsonify, render_template
from app.config import Config


def load_deployment_status(file_path):
    """Safely read the latest deployment record from the history file.

    Returns a dict with 'status' and 'timestamp'. If the file is missing, empty,
    or contains invalid JSON, defaults to 'No deployment history yet' and 'N/A'.
    """
    default_result = {
        "status": "No deployment history yet",
        "timestamp": "N/A",
    }

    if not file_path:
        return default_result

    path = Path(file_path)
    if not path.is_file():
        return default_result

    try:
        content = path.read_text(encoding="utf-8").strip()
        if not content:
            return default_result

        records = json.loads(content)
        if isinstance(records, list) and len(records) > 0:
            last_record = records[-1]
            if isinstance(last_record, dict):
                status = last_record.get("status")
                if status is None:
                    status = "unknown"
                timestamp = last_record.get("timestamp") or "N/A"
                return {
                    "status": status,
                    "timestamp": timestamp,
                }
        return default_result
    except Exception:
        return default_result


def create_app(config_overrides=None):
    """Application factory for the AutoDeploy Flask service."""
    app = Flask(__name__)
    app.config.from_object(Config)

    if config_overrides:
        app.config.update(config_overrides)

    @app.route("/")
    def index():
        history_file = current_app.config.get("DEPLOY_HISTORY_FILE")
        deployment_info = load_deployment_status(history_file)
        commit_sha = current_app.config.get("GIT_COMMIT_SHA", "unknown")
        short_commit_sha = (
            commit_sha[:7] if commit_sha and commit_sha != "unknown" else "unknown"
        )

        return render_template(
            "index.html",
            name=current_app.config.get("APP_NAME", "AutoDeploy"),
            version=current_app.config.get("APP_VERSION", "1.0.0"),
            commit_sha=commit_sha,
            short_commit_sha=short_commit_sha,
            build_time=current_app.config.get("BUILD_TIME", "unknown"),
            environment=current_app.config.get("DEPLOY_ENV", "local"),
            deployment_status=deployment_info["status"],
            deployment_timestamp=deployment_info["timestamp"],
        )

    @app.route("/health")
    def health():
        return jsonify({
            "status": "healthy",
            "application": current_app.config.get("APP_NAME", "AutoDeploy"),
            "version": current_app.config.get("APP_VERSION", "1.0.0"),
        }), 200

    @app.route("/version")
    def version():
        return jsonify({
            "application": current_app.config.get("APP_NAME", "AutoDeploy"),
            "version": current_app.config.get("APP_VERSION", "1.0.0"),
            "commit_sha": current_app.config.get("GIT_COMMIT_SHA", "unknown"),
            "build_time": current_app.config.get("BUILD_TIME", "unknown"),
            "environment": current_app.config.get("DEPLOY_ENV", "local"),
        }), 200

    @app.errorhandler(404)
    def not_found(error):
        return jsonify({"error": "not found"}), 404

    return app


app = create_app()

