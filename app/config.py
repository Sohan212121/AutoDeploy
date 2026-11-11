import os


class Config:
    """Application configuration reading environment variables with safe defaults."""

    APP_NAME = os.getenv("APP_NAME", "AutoDeploy")
    APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
    GIT_COMMIT_SHA = os.getenv("GIT_COMMIT_SHA", "unknown")
    BUILD_TIME = os.getenv("BUILD_TIME", "unknown")
    DEPLOY_ENV = os.getenv("DEPLOY_ENV", "local")
    DEPLOY_HISTORY_FILE = os.getenv("DEPLOY_HISTORY_FILE", "deployment_history.json")

