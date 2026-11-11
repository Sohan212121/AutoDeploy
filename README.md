# AutoDeploy

An end-to-end automated CI/CD, containerization, and self-healing deployment pipeline built with **Python/Flask**, **Docker**, **GitHub Actions**, **GitHub Container Registry (GHCR)**, and a **Windows self-hosted GitHub Actions runner**.

---

## Overview

**AutoDeploy** demonstrates a complete DevOps delivery workflow from source commit to verified live deployment with automatic rollback on failure. A lightweight Flask web application exposes deployment metadata (`APP_NAME`, `APP_VERSION`, `GIT_COMMIT_SHA`, `BUILD_TIME`, `DEPLOY_ENV`) and the latest deployment record via a web portal (`GET /`) and JSON endpoints (`GET /health`, `GET /version`).

Every push to `main` runs automated tests, builds and smoke-tests a hardened non-root Docker image, publishes immutable SHA-tagged images to `ghcr.io`, and triggers a PowerShell deployment script on a local Windows PC via a self-hosted runner—verifying container health and `/version` SHA consistency, and rolling back automatically if verification fails.

---

## Problem Statement

Manual application deployments suffer from:
1. **"Works on my machine" drift** across Python versions, OS dependencies, and environment configuration.
2. **Unverified releases** where a broken commit or misconfigured container silently replaces a working service.
3. **Slow, error-prone manual rollbacks** when a new release fails health checks after deployment.
4. **Lack of deployment observability** (no reliable record of which Git commit, image tag, or timestamp is actually running).

---

## Proposed Solution

AutoDeploy solves these issues using four integrated controls:
1. **Immutable, Parameterized Containers**: Package the Flask + Gunicorn app into `python:3.13-slim` with `APP_VERSION`, `GIT_COMMIT_SHA`, and `BUILD_TIME` baked in at build time and runtime environment overrides injected cleanly.
2. **Automated CI Quality Gate & Smoke Test**: Block image publishing unless `pytest -v` passes (`7/7` tests) and a container smoke test confirms HTTP 200 on `/health` plus commit SHA parity on `/version`.
3. **Verified CD with Automatic Rollback**: Pull the exact `${{ github.sha }}` image on the target Windows host, verify Docker `HEALTHCHECK` (`healthy`), `/health` (`200`), and `/version` (`commit_sha == Tag`), and automatically restore the previous healthy image if any check fails.
4. **Persistent Deployment Audit Trail**: Append structured JSON records (`success`, `rolled_back`, `failed`) to `deployment_history.json` on the host, mounted read-only (`/data:ro`) into the container so the web UI reflects real deployment status.

---

## Objectives

- Build a clean, testable Flask application following the application factory pattern (`create_app`).
- Containerize the service cleanly using a non-root user (`appuser`, UID `10001`), dependency layer caching, and a built-in Python `HEALTHCHECK`.
- Automate testing, smoke verification, and GHCR publishing on GitHub Actions using only the built-in `GITHUB_TOKEN`.
- Automate local Windows deployment via a self-hosted runner with health-gated verification and automated rollback.
- Maintain a persistent, valid JSON deployment history and commit-pinned rollback state (`last_good_tag.txt`).

---

## Technology Stack

Only technologies actually used in this project:

| Layer | Technology | Version / Details |
| --- | --- | --- |
| Language & Runtime | Python | `3.13` (`python:3.13-slim` in Docker) |
| Web Framework | Flask | `3.1.0` |
| Production WSGI Server | Gunicorn | `23.0.0` (`2` workers bound to `0.0.0.0:8000`) |
| Automated Testing | pytest | `8.3.4` (`7` unit/integration tests) |
| Frontend UI | Jinja2 + HTML5 + CSS3 | Responsive portal served from `app/templates/index.html` & `app/static/style.css` |
| Containerization | Docker & Docker Compose | Docker Desktop (Windows / Linux engine) |
| Container Registry | GitHub Container Registry (`ghcr.io`) | Public image `ghcr.io/sohan212121/autodeploy` (`:latest` & `:<sha>`) |
| CI/CD Automation | GitHub Actions | Cloud runners (`ubuntu-latest`) + Windows `self-hosted` runner |
| Deployment Scripting | Windows PowerShell | `5.1` (`deployment/deploy.ps1`) |
| State & History Storage | Local JSON & Text Files | `%USERPROFILE%\autodeploy-data\deployment_history.json` & `last_good_tag.txt` |

---

## Architecture Diagram

```text
+-------------------+       git push (main)       +----------------------------------------+
| Developer PC      | --------------------------> | GitHub Repository (Sohan212121/AutoDeploy)
+-------------------+                             +----------------------------------------+
                                                                      |
                                                                      v webhook (push / workflow_dispatch)
+---------------------------------------------------------------------------------------------------+
| GitHub Actions Workflow (.github/workflows/deploy.yml)                                            |
|                                                                                                   |
|  [Job 1: test (ubuntu-latest)]                                                                    |
|     Checkout -> Setup Python 3.13 -> pip install -> env -u APP_VERSION pytest -v (7 tests)       |
|                                           | (needs: test)                                         |
|                                           v                                                       |
|  [Job 2: build-and-push (ubuntu-latest)]                                                          |
|     Build smoke image -> docker run -> curl /health (200) & /version (github.sha) -> Cleanup      |
|     -> Login GHCR (GITHUB_TOKEN) -> Build & Push ghcr.io/sohan212121/autodeploy:latest & :<sha>  |
|                                           | (needs: build-and-push)                               |
|                                           v                                                       |
|  [Job 3: deploy (runs-on: self-hosted | Windows PC)]                                              |
|     Checkout -> Run deployment/deploy.ps1 -ImageName ghcr.io/sohan212121/autodeploy -Tag <sha>   |
+---------------------------------------------------------------------------------------------------+
                                                                      |
                                                                      v executes locally
+---------------------------------------------------------------------------------------------------+
| Local Windows Target Host (Docker Desktop + Self-Hosted Runner)                                   |
|                                                                                                   |
|  deploy.ps1:                                                                                      |
|    1. Read previous running image & last_good_tag.txt                                             |
|    2. docker pull ghcr.io/sohan212121/autodeploy:<sha>                                            |
|    3. Stop/remove old autodeploy-app -> docker run (-p 127.0.0.1:8000:8000, -v .../autodeploy-data:/data:ro)
|    4. Poll up to 60s: Docker health == "healthy" AND /health == 200 AND /version.commit_sha == <sha>
|       |-- PASS --> Append "success" to deployment_history.json & save <sha> to last_good_tag.txt  |
|       '-- FAIL --> Remove failed container -> Re-run previous image -> Verify healthy            |
|                    -> Append "rolled_back" & "failed" records -> Exit 1                           |
+---------------------------------------------------------------------------------------------------+
```

---

## Directory Structure

```text
AutoDeploy/
├── .dockerignore
├── .env.example
├── .github/
│   └── workflows/
│       └── deploy.yml          # CI/CD workflow (test, build-and-push, deploy)
├── .gitignore
├── Dockerfile                  # Non-root python:3.13-slim container + HEALTHCHECK + Gunicorn
├── README.md                   # Project documentation
├── app/
│   ├── __init__.py
│   ├── app.py                  # Flask application factory & routes (/, /health, /version)
│   ├── config.py               # Environment-driven Config class with safe defaults
│   ├── static/
│   │   └── style.css           # Dashboard styling
│   └── templates/
│       └── index.html          # Deployment portal HTML template
├── deployment/
│   └── deploy.ps1              # Automated pull, deploy, health-check & rollback script
├── docker-compose.yml          # Local Docker Compose definition
├── docs/
│   └── PROJECT_REPORT.md       # Detailed project report, test logs & 20 viva Q&As
├── pytest.ini                  # pytest configuration (testpaths = tests, pythonpath = .)
├── requirements.txt            # Pinned Python packages (flask, gunicorn, pytest)
└── tests/
    ├── __init__.py
    ├── conftest.py             # Shared pytest fixtures (client, history_file)
    └── test_app.py             # 7 automated unit & integration tests
```

---

## Local Run Instructions (Windows)

Run the application directly on Windows using PowerShell:

```powershell
# 1. Create and activate a virtual environment
python -m venv venv
.\venv\Scripts\Activate.ps1

# 2. Install pinned dependencies
pip install -r requirements.txt

# 3. Optional: set environment variables (never commit a real .env)
$env:APP_VERSION = "1.0.0"
$env:DEPLOY_ENV = "local"
$env:GIT_COMMIT_SHA = (git rev-parse HEAD)

# 4. Start the Flask development server
python -m flask --app app.app:app run --host 127.0.0.1 --port 8000
```

Verify locally:
- Portal UI: `http://127.0.0.1:8000/`
- Health endpoint: `http://127.0.0.1:8000/health`
- Version endpoint: `http://127.0.0.1:8000/version`

---

## Docker Instructions

### Build and Run with `docker`

```powershell
$sha = git rev-parse HEAD
$buildTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

docker build `
  --build-arg APP_VERSION=1.0.0 `
  --build-arg GIT_COMMIT_SHA=$sha `
  --build-arg BUILD_TIME=$buildTime `
  --build-arg DEPLOY_ENV=local `
  -t autodeploy:local .

docker run -d `
  --name autodeploy-local `
  -p 127.0.0.1:8000:8000 `
  -e DEPLOY_ENV=local `
  autodeploy:local
```

### Build and Run with Docker Compose

```powershell
docker compose up --build -d
docker compose ps
docker compose down
```

`docker-compose.yml` builds the image with `${APP_VERSION:-1.0.0}`, `${GIT_COMMIT_SHA:-unknown}`, and `${BUILD_TIME:-unknown}`, mounts named volume `autodeploy-data:/data`, sets `DEPLOY_ENV=local`, and runs the `/health` check every 15s.

---

## GitHub Actions Explanation (`.github/workflows/deploy.yml`)

The workflow **AutoDeploy CI/CD** triggers on `push` to `main` and `workflow_dispatch`, uses minimal top-level `contents: read` permissions, sets `APP_VERSION: "1.1.0"`, and guards against overlapping runs via `concurrency: autodeploy-${{ github.ref }}`.

1. **`test` (`Run Automated Test Suite`, `runs-on: ubuntu-latest`)**
   - Checks out the repository, sets up Python 3.13 with `pip` caching, installs `requirements.txt`, and runs `env -u APP_VERSION pytest -v`.
   - Unsetting `APP_VERSION` ensures `test_app_starts_and_creates_without_error` verifies the application's default `"1.0.0"` config fallback even when workflow `APP_VERSION` is bumped (e.g., `"1.1.0"`).

2. **`build-and-push` (`Build Container & Push to GHCR`, `needs: test`, `runs-on: ubuntu-latest`)**
   - Permissions: `contents: read`, `packages: write`.
   - Computes lowercase `IMAGE=ghcr.io/${GITHUB_REPOSITORY,,}` and UTC `BUILD_TIME`.
   - Builds `autodeploy:smoke` locally (`load: true`, `push: false`) with GitHub Actions layer cache (`type=gha`).
   - Starts `smoke` container on port `8000`, polls `/health` until HTTP `200`, verifies `/version` contains `${{ github.sha }}`, and always removes the `smoke` container (`if: always()`).
   - Logs in to `ghcr.io` with `docker/login-action@v3` and `${{ secrets.GITHUB_TOKEN }}`, pushes `${{ env.IMAGE }}:latest` and `${{ env.IMAGE }}:${{ github.sha }}`, and publishes a build summary.

3. **`deploy` (`Deploy to Local Self-Hosted Runner`, `needs: build-and-push`, `runs-on: self-hosted`)**
   - Permissions: `contents: read` only (no login step required because `ghcr.io/sohan212121/autodeploy` is public, verified with unauthenticated `docker pull` after `docker logout ghcr.io`).
   - Serializes deployments with `concurrency: autodeploy-deploy`.
   - Checks out the repo, executes `deployment/deploy.ps1 -ImageName ghcr.io/<repo_lowercase> -Tag "${{ github.sha }}"`, passing `SIMULATE_FAILURE=true` if the head commit message contains `[simulate-failure]`.
   - Runs an `if: always()` step printing the last 20 entries from `deployment_history.json` and writing a Markdown summary to `$GITHUB_STEP_SUMMARY`.

---

## Self-Hosted Runner Setup Steps (Windows)

Summary of how the local Windows runner is configured (without exposing any registration tokens):

1. Ensure **Docker Desktop** is installed and running on Windows (Linux containers engine).
2. In the GitHub repository go to **Settings → Actions → Runners → New self-hosted runner** and choose **Windows (x64)**.
3. Download and extract the GitHub Actions runner package into a dedicated folder (e.g., `F:\actions-runner`).
4. Run `.\config.cmd --url https://github.com/Sohan212121/AutoDeploy --token <REGISTRATION_TOKEN>` from `F:\actions-runner`, keeping default labels (`self-hosted, Windows, X64`).
5. Start the runner with `.\run.cmd` (or register it as a Windows service during setup so it starts on boot).
6. Make sure Docker CLI (`docker.exe`) is available to the runner user (`deployment/deploy.ps1` also automatically prepends Docker Desktop's default Windows bin paths if missing from `PATH`).

---

## How to Deploy

Every push to `main` deploys automatically once CI tests and container smoke checks pass:

```powershell
git add .
git commit -m "feat: update application"
git push origin main
```

You can also trigger a deployment manually from the GitHub **Actions** tab via **Run workflow** (`workflow_dispatch`).

---

## How Rollback Works

Rollback is implemented in [`deployment/deploy.ps1`](file:///f:/DevOps/AutoDeploy/deployment/deploy.ps1):

1. **Snapshot Before Change**: Before pulling or stopping anything, `deploy.ps1` inspects the currently running `autodeploy-app` container for its image reference (`$PreviousImage`) and reads `$env:USERPROFILE\autodeploy-data\last_good_tag.txt` (`$LastGoodTag`).
2. **Pull & Replace**: Pulls `ghcr.io/sohan212121/autodeploy:<commit_sha>`, stops/removes the existing container, and starts the new one.
3. **Strict 60-Second Health Gate**: Polls Docker's `{{.State.Health.Status}}` (`healthy`, failing fast on `unhealthy` or container exit), `GET http://127.0.0.1:8000/health` (`200`), and `GET http://127.0.0.1:8000/version` (`commit_sha == <Tag>`).
4. **Automatic Rollback on Any Failure**:
   - Stops and removes the failed container (without deleting the previous local image).
   - Restarts `autodeploy-app` using `$PreviousImage` without failure simulation.
   - Polls up to 60s to verify the rolled-back container is `healthy` and serves `$LastGoodTag` on `/version`.
   - Records a `"rolled_back"` entry (if rollback succeeded) followed by a `"failed"` entry in `deployment_history.json`, leaving `last_good_tag.txt` unchanged.
   - Exits with code `1` so the GitHub Actions `deploy` job marks the release as failed.

---

## How to Test Rollback with `[simulate-failure]`

`deploy.yml` inspects the commit message for `[simulate-failure]`. When present, `SIMULATE_FAILURE=true` instructs `deploy.ps1` to launch the new container with `--entrypoint sleep 3600` so `/health` never responds and Docker marks it `unhealthy`:

```powershell
git commit --allow-empty -m "test: rollback check [simulate-failure]"
git push origin main
```

Expected outcome:
- `test` and `build-and-push` jobs succeed.
- `deploy` job fails after the new container reports `unhealthy`, automatically rolls back to the previous image, records `"rolled_back"` + `"failed"` in `deployment_history.json`, and keeps `http://localhost:8000/version` serving the previous good commit SHA.

To recover normally afterwards:

```powershell
git commit --allow-empty -m "test: recovery"
git push origin main
```

---

## Testing Instructions

Run the automated Python test suite locally in PowerShell:

```powershell
.\venv\Scripts\python.exe -m pytest -v
```

Validate YAML workflow syntax and PowerShell script syntax:

```powershell
.\venv\Scripts\python.exe -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml', encoding='utf-8')); print('YAML valid')"
powershell -NoProfile -Command "`$e=$null; [System.Management.Automation.Language.Parser]::ParseFile('deployment\deploy.ps1',[ref]`$null,[ref]`$e)|Out-Null; Write-Output ('Parse errors: ' + `$e.Count)"
```

---

## Security Considerations

- **Built-in `GITHUB_TOKEN` only**: No PATs, SSH keys, or cloud credentials are stored or required.
- **Least-privilege permissions**: Workflow-level and `deploy` job permissions are strictly `contents: read`; `packages: write` is scoped solely to `build-and-push`.
- **No secrets in repository**: `.gitignore` and `.dockerignore` exclude `.env`, `.env.*`, `*.pem`, `*.key`, and local data files; only `.env.example` with non-sensitive sample values is tracked.
- **Non-root container execution**: `Dockerfile` creates `appuser` (UID `10001`) and runs Gunicorn as `USER appuser`.
- **Localhost port binding & read-only mount**: `deploy.ps1` binds `127.0.0.1:8000:8000` (not `0.0.0.0`) so the app is not exposed directly on the LAN, and mounts `%USERPROFILE%\autodeploy-data` as `/data:ro` inside the container.
- **Self-hosted runner on a public repo**: Because a self-hosted runner executes workflows directly on the developer's Windows host, **only `push` (to `main`) and `workflow_dispatch` triggers are enabled**. `pull_request` triggers are intentionally omitted so external contributors cannot run arbitrary code on the local PC via fork PRs.

---

## Screenshots

> _Placeholder section — capture and place screenshots under `docs/screenshots/` if needed for presentation._

- `[Screenshot Placeholder 1]`: Web Portal (`http://localhost:8000/`) displaying live version `1.1.0`, short/full commit SHA, and `"success"` status badge.
- `[Screenshot Placeholder 2]`: GitHub Actions workflow graph showing all 3 jobs (`Run Automated Test Suite`, `Build Container & Push to GHCR`, `Deploy to Local Self-Hosted Runner`) passing.
- `[Screenshot Placeholder 3]`: GitHub Actions run showing simulated rollback (`test` + `build-and-push` green, `deploy` failed with rollback logs and `deployment_history.json` entries).

---

## Limitations

- **Local Windows Target Only**: Deployments run on the developer's own Windows PC using Docker Desktop and a local self-hosted runner. **AWS EC2 and Nginx were NOT implemented** in this project.
- **Host Availability Dependency**: Continuous delivery and application uptime depend on the Windows PC staying powered on, connected to the internet, and running Docker Desktop + `Runner.Listener.exe`.
- **No External Public URL / HTTPS**: Port `8000` is bound to `127.0.0.1` over plain HTTP without a reverse proxy or TLS certificate.
- **Brief Downtime Window**: `deploy.ps1` uses stop-and-replace on a single `autodeploy-app` container on port `8000`, resulting in a few seconds of downtime during container replacement.

---

## Future Enhancements

- **AWS EC2 Deployment Target**: Provision an Ubuntu EC2 instance and deploy via SSH / OIDC / remote runner for 24/7 cloud availability.
- **Nginx Reverse Proxy & TLS**: Add Nginx with Let's Encrypt HTTPS and clean HTTP routing instead of exposing Gunicorn directly on localhost.
- **Deployment History Web Dashboard**: Expand the Flask UI to render the full history table (`success`, `rolled_back`, `failed`) with filtering and error details.
- **Telegram / Slack Notifications**: Send real-time alerts with commit SHA, environment, and rollback outcomes from `deploy.ps1` or GitHub Actions.
- **Zero-Downtime Blue-Green Switching**: Run green and blue containers on alternating ports behind Nginx/health checks and switch upstream traffic only after passing verification.
