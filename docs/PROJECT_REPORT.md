# AutoDeploy — Project Report

**Repository:** `https://github.com/Sohan212121/AutoDeploy`  
**Deployment Target:** Local Windows PC (Docker Desktop + Self-Hosted GitHub Actions Runner)  
**Latest Verified Release:** `1.1.0` (`54a126af7723dc69e9742f06ce68777611838ac8`)

---

## 1. Abstract

**AutoDeploy** is a DevOps mini project implementing an automated Continuous Integration and Continuous Deployment (CI/CD) pipeline with containerization, registry distribution, live health verification, and automatic rollback. A Python Flask web application (`app/`) exposes build metadata and deployment history over HTTP (`/`), JSON health (`/health`), and version inspection (`/version`) endpoints.

When code is pushed to `main`, GitHub Actions automatically executes unit tests (`pytest`), builds a hardened non-root Docker image (`python:3.13-slim` + Gunicorn), smoke-tests the container, pushes immutable SHA-tagged images to GitHub Container Registry (`ghcr.io`), and invokes a PowerShell deployment script (`deployment/deploy.ps1`) on a Windows self-hosted runner. All deployment outcomes are persisted to `deployment_history.json`. In real verification runs—including a simulated failure (`[simulate-failure]`) and a live version bump (`1.0.0` → `1.1.0`)—the pipeline passed automated tests, published verified images, rejected an unhealthy container via automatic rollback, and recovered cleanly on the subsequent commit.

---

## 2. Problem Statement

Software teams frequently encounter deployment failures caused by inconsistent runtime environments, unverified manual steps, missing version traceability, and risky manual rollbacks. Even small web services can suffer extended outages if a faulty release replaces a healthy instance without automated health gating and fallback mechanisms.

This project addresses those challenges by designing an end-to-end automated pipeline where:
- Every release is tested and smoke-verified before leaving CI.
- Container images are tagged with exact Git commit SHAs rather than relying solely on mutable `:latest`.
- Every local deployment verifies both container health and served commit SHA before marking success, and rolls back automatically on failure.

---

## 3. Proposed Methodology

The implementation follows a four-stage DevOps lifecycle:

1. **Environment-Driven Application Design**: Decouple all metadata (`APP_NAME`, `APP_VERSION`, `GIT_COMMIT_SHA`, `BUILD_TIME`, `DEPLOY_ENV`, `DEPLOY_HISTORY_FILE`) from code via `Config` and `create_app()`.
2. **Immutable Container Packaging**: Package only `app/` and pinned `requirements.txt` into a slim Python 3.13 image running Gunicorn under a non-root user (`appuser`, UID `10001`), with an internal Python `HEALTHCHECK`.
3. **CI Pipeline (`test` → `build-and-push`)**: Run automated `pytest` checks first, build and smoke-test the container locally on `ubuntu-latest`, and push `:latest` and `:<github.sha>` tags to GHCR only if all checks pass.
4. **Verified Local CD & Rollback (`deploy`)**: On the Windows self-hosted runner, snapshot the active container image and `last_good_tag.txt`, pull the exact SHA tag, replace `autodeploy-app`, poll health and `/version` for up to 60 seconds, and either commit the new state (`"success"`) or restore the previous image (`"rolled_back"` + `"failed"`).

---

## 4. System Architecture Explanation

AutoDeploy spans three execution environments:

1. **Developer Workstation (Source Control)**: Changes are committed to `main` and pushed to `https://github.com/Sohan212121/AutoDeploy`.
2. **GitHub Cloud (`ubuntu-latest` + GHCR)**:
   - The `test` job validates application logic in isolation.
   - The `build-and-push` job builds the container image with GitHub Actions cache (`type=gha`), verifies `/health` (`200`) and `/version` (`commit_sha`), authenticates with `GITHUB_TOKEN`, and pushes to `ghcr.io/sohan212121/autodeploy`.
3. **Local Windows Host (`F:\actions-runner` + Docker Desktop)**:
   - Because the GHCR repository package is public (verified with an unauthenticated `docker pull` after `docker logout ghcr.io`), the `deploy` job runs with `contents: read` permissions only and invokes `deployment/deploy.ps1`.
   - `deploy.ps1` runs `autodeploy-app` bound to `127.0.0.1:8000:8000` and mounts `%USERPROFILE%\autodeploy-data` read-only at `/data:ro`.
   - **Important Architectural Scope Note**: The live deployment target is the developer's own Windows PC using Docker Desktop and a Windows self-hosted runner. **AWS EC2 and Nginx were NOT implemented** in this phase.

---

## 5. Module Descriptions

### 5.1 Application Module (`app/`)
- **`app/config.py`**: Defines `Config`, reading `APP_NAME` (`"AutoDeploy"`), `APP_VERSION` (`"1.0.0"`), `GIT_COMMIT_SHA` (`"unknown"`), `BUILD_TIME` (`"unknown"`), `DEPLOY_ENV` (`"local"`), and `DEPLOY_HISTORY_FILE` (`"deployment_history.json"`) from environment variables.
- **`app/app.py`**: Implements `create_app(config_overrides=None)` and module-level `app = create_app()` for Gunicorn. Defines:
  - `load_deployment_status(file_path)`: Safely parses the JSON array in `DEPLOY_HISTORY_FILE`, returning the last record's `status` and `timestamp`, or `"No deployment history yet"` / `"N/A"` if missing, empty, or malformed.
  - `GET /`: Renders `templates/index.html` with application metadata, 7-char and full commit SHA, and last deployment status.
  - `GET /health`: Returns `{"status": "healthy", "application": ..., "version": ...}` with HTTP `200`.
  - `GET /version`: Returns `{"application", "version", "commit_sha", "build_time", "environment"}` with HTTP `200`.
  - Custom `404` handler returning `{"error": "not found"}`.
- **`app/templates/index.html` & `app/static/style.css`**: Styled web portal displaying metadata cards and deployment status badges.

### 5.2 Test Suite (`tests/` & `pytest.ini`)
- **`tests/conftest.py`**: Provides `history_file` (`tmp_path / "deployment_history.json"`) and `client` fixtures overriding `APP_VERSION="9.9.9-test"` and `GIT_COMMIT_SHA="abc1234def"`.
- **`tests/test_app.py`**: Contains 7 tests covering app factory defaults and overrides, `GET /` rendering, `GET /health`, `GET /version` dynamic config, `404` JSON errors, displaying valid deployment history, and graceful fallback when history is missing, empty, or invalid JSON.

### 5.3 Containerization (`Dockerfile`, `.dockerignore`, `docker-compose.yml`)
- **`Dockerfile`**: Uses `python:3.13-slim`, sets `PYTHONDONTWRITEBYTECODE=1` and `PYTHONUNBUFFERED=1`, caches `pip install --no-cache-dir -r requirements.txt`, copies only `app/`, maps build args (`APP_VERSION`, `GIT_COMMIT_SHA`, `BUILD_TIME`, `DEPLOY_ENV`) to `ENV`, sets `DEPLOY_HISTORY_FILE=/data/deployment_history.json`, runs as non-root `appuser` (UID `10001`), checks `http://127.0.0.1:8000/health` via Python `urllib.request`, and launches `gunicorn --workers 2 --bind 0.0.0.0:8000 app.app:app`.
- **`.dockerignore`**: Excludes `venv/`, tests, `.git/`, `.github/`, `.env*`, secrets, docs, and deployment scripts from build context.
- **`docker-compose.yml`**: Single service `autodeploy` with `autodeploy-data:/data` volume and matching `/health` check for local Docker Compose workflows.

### 5.4 CI Jobs (`.github/workflows/deploy.yml`)
- **`test`**: Runs on `ubuntu-latest` with Python 3.13 and `env -u APP_VERSION pytest -v` (unsetting workflow-level `APP_VERSION` so `Config` default `"1.0.0"` is cleanly tested alongside version bumps).
- **`build-and-push`**: Runs on `ubuntu-latest` with `contents: read` and `packages: write`; builds `autodeploy:smoke`, runs live container `/health` + `/version` verification, logs in to `ghcr.io` with `GITHUB_TOKEN`, and pushes `:latest` and `:<github.sha>`.

### 5.5 Local Deployment Script (`deployment/deploy.ps1` & `deploy` job)
- **`deploy` job**: Runs on `self-hosted` with `contents: read` and concurrency group `autodeploy-deploy`. Evaluates `[simulate-failure]` in the commit message to set `SIMULATE_FAILURE`, invokes `deployment/deploy.ps1`, and prints the last 20 history records plus `$GITHUB_STEP_SUMMARY` via `if: always()`.
- **`deployment/deploy.ps1`**: Ensures Docker CLI PATH availability, creates `%USERPROFILE%\autodeploy-data`, pulls `ghcr.io/sohan212121/autodeploy:<Tag>`, replaces `autodeploy-app` on `127.0.0.1:8000:8000`, and polls up to 60s for Docker health `healthy`, HTTP `/health` `200`, and `/version` `commit_sha == Tag`.

### 5.6 Rollback & History Modules (within `deployment/deploy.ps1`)
- **Rollback**: Records `$PreviousImage` (`docker inspect`) and `$LastGoodTag` (`last_good_tag.txt`) before pulling. On any pull, run, or verification failure, removes the failed container (preserving the previous local image), re-launches `$PreviousImage` without `SIMULATE_FAILURE`, re-verifies health and `$LastGoodTag`, and exits `1`.
- **History**: Writes UTF-8 (no BOM) JSON arrays via `ConvertTo-Json -InputObject @($records) -Depth 5` to `deployment_history.json` with schema keys `deployment_id`, `commit_sha`, `image_tag`, `timestamp`, `status`, `environment`, and `error`.

---

## 6. Testing Results (Real Observed Outputs)

### 6.1 Summary Table

| Test Area | Scope / Trigger | Run ID / Command | Outcome | Key Observed Evidence |
| --- | --- | --- | --- | --- |
| **Unit & Integration Tests** | Flask app, config, templates, health/version/404, history parsing | `.\venv\Scripts\python.exe -m pytest -v` | **PASS** (`7 passed in 0.17s`) | All 7 tests in `tests/test_app.py` passed (`0` failures, `0` skipped) |
| **Release Validation (Fix)** | Unset `APP_VERSION` in pytest check | `APP_VERSION=1.1.0` vs unset | **Verified** | Confirmed `APP_VERSION=1.1.0` caused `1 failed` (`test_app_starts_and_creates_without_error`); unsetting restored `7 passed in 0.08s` |
| **Docker & Unauthenticated Pull** | Non-root slim image, healthcheck, GHCR public pull | `docker logout ghcr.io` + `docker pull ...:203cd77...` | **PASS** (`PULL EXIT: 0`) | Downloaded digest `sha256:0f7618...` without registry credentials |
| **Initial CI Pipeline** | Initial `test` + `build-and-push` on `4f80b6a` | Run [`43007758747`](https://github.com/Sohan212121/AutoDeploy/actions/runs/43007758747) | **PASS** (`57s`) | `AutoDeploy CI/CD #1` completed successfully |
| **Test A (Normal Deploy)** | Push `203cd77` (`fix: avoid UTF-8 BOM...`) | Run [`43016759133`](https://github.com/Sohan212121/AutoDeploy/actions/runs/43016759133) | **PASS** | All 3 jobs `success`; `/version` returned `203cd77...`; history recorded `"success"` |
| **Test B (Rollback Proof)** | Push `661d618` (`test: rollback check [simulate-failure]`) | Run [`43017134993`](https://github.com/Sohan212121/AutoDeploy/actions/runs/43017134993) | **PASS** (Expected `deploy` failure + rollback) | `test` & `build-and-push` `success`; `deploy` `failed` (`unhealthy`); `/version` stayed at `203cd77...` (`healthy`); history recorded `"rolled_back"` + `"failed"` |
| **Test C (Recovery)** | Push `631f422` (`test: recovery`) | Run [`43018080633`](https://github.com/Sohan212121/AutoDeploy/actions/runs/43018080633) | **PASS** | All 3 jobs `success`; `/version` updated to `631f422...`; history recorded `"success"` |
| **Workflow Cleanup Verify** | Push `5514cde` (removed GHCR login step in `deploy`) | Run [`43021119988`](https://github.com/Sohan212121/AutoDeploy/actions/runs/43021119988) | **PASS** | All 3 jobs `success` with `contents: read` only in `deploy` |
| **Live Demo (v1.1.0 Leak Catch)** | Push `562885b` (`release: version 1.1.0`) | Run [`43022201536`](https://github.com/Sohan212121/AutoDeploy/actions/runs/43022201536) | **Caught by CI** (`14s`) | `test` failed because workflow `APP_VERSION=1.1.0` leaked into pytest default check |
| **Live Demo (v1.1.0 Success)** | Push `54a126a` (`env -u APP_VERSION pytest -v`) | Run [`43023387754`](https://github.com/Sohan212121/AutoDeploy/actions/runs/43023387754) | **PASS** | All 3 jobs `success`; `/version` & `/health` returned `"version": "1.1.0"` and `"commit_sha": "54a126af7723dc69e9742f06ce68777611838ac8"`; `/` displayed `1.1.0` |

### 6.2 Actual `deployment_history.json` Proof (Tests A, B, C, Cleanup, & v1.1.0)

```json
[
    {
        "deployment_id":  "43016759133",
        "commit_sha":  "203cd773cb243b281390b087b3a575312583b959",
        "image_tag":  "ghcr.io/sohan212121/autodeploy:203cd773cb243b281390b087b3a575312583b959",
        "timestamp":  "2026-11-11T12:03:51Z",
        "status":  "success",
        "environment":  "local",
        "error":  ""
    },
    {
        "deployment_id":  "43017134993",
        "commit_sha":  "661d618d8fc3ba6c2cc018a9d00d1c1fa1dfdcc3",
        "image_tag":  "ghcr.io/sohan212121/autodeploy:661d618d8fc3ba6c2cc018a9d00d1c1fa1dfdcc3",
        "timestamp":  "2026-11-11T12:07:15Z",
        "status":  "rolled_back",
        "environment":  "local",
        "error":  "Rolled back to ghcr.io/sohan212121/autodeploy:203cd773cb243b281390b087b3a575312583b959 after failure: Container \u0027autodeploy-app\u0027 reported Docker health status \u0027unhealthy\u0027"
    },
    {
        "deployment_id":  "43017134993",
        "commit_sha":  "661d618d8fc3ba6c2cc018a9d00d1c1fa1dfdcc3",
        "image_tag":  "ghcr.io/sohan212121/autodeploy:661d618d8fc3ba6c2cc018a9d00d1c1fa1dfdcc3",
        "timestamp":  "2026-11-11T12:07:15Z",
        "status":  "failed",
        "environment":  "local",
        "error":  "Container \u0027autodeploy-app\u0027 reported Docker health status \u0027unhealthy\u0027"
    },
    {
        "deployment_id":  "43018080633",
        "commit_sha":  "631f42254dc8b0f4149f5709947371fb35c9c7d2",
        "image_tag":  "ghcr.io/sohan212121/autodeploy:631f42254dc8b0f4149f5709947371fb35c9c7d2",
        "timestamp":  "2026-11-11T12:12:59Z",
        "status":  "success",
        "environment":  "local",
        "error":  ""
    },
    {
        "deployment_id":  "43021119988",
        "commit_sha":  "5514cde2ff0feb1cf19a4074b52ea9c7283c7139",
        "image_tag":  "ghcr.io/sohan212121/autodeploy:5514cde2ff0feb1cf19a4074b52ea9c7283c7139",
        "timestamp":  "2026-11-11T12:34:03Z",
        "status":  "success",
        "environment":  "local",
        "error":  ""
    },
    {
        "deployment_id":  "43023387754",
        "commit_sha":  "54a126af7723dc69e9742f06ce68777611838ac8",
        "image_tag":  "ghcr.io/sohan212121/autodeploy:54a126af7723dc69e9742f06ce68777611838ac8",
        "timestamp":  "2026-11-11T12:49:37Z",
        "status":  "success",
        "environment":  "local",
        "error":  ""
    }
]
```

### 6.3 Live v1.1.0 Verification Outputs
- `GET http://localhost:8000/version`:
  ```json
  {"application":"AutoDeploy","build_time":"2026-11-11T12:47:49Z","commit_sha":"54a126af7723dc69e9742f06ce68777611838ac8","environment":"local","version":"1.1.0"}
  ```
- `GET http://localhost:8000/health`:
  ```json
  {"application":"AutoDeploy","status":"healthy","version":"1.1.0"}
  ```

---

## 7. Advantages

- **Zero Manual Steps After `git push`**: Testing, building, registry publishing, local deployment, and verification execute automatically.
- **Deterministic Rollbacks**: Pinning containers by full commit SHA (`<sha>`) guarantees rollback pulls/runs the exact verified prior artifact.
- **Defense in Depth**: Combines unit tests (`pytest`), CI container smoke tests, Docker `HEALTHCHECK`, and post-deploy `/version` SHA matching.
- **Zero Static Cloud Secrets**: Uses only GitHub's short-lived `GITHUB_TOKEN` with minimal job permissions.
- **Container Hardening**: Runs Gunicorn as non-root `appuser`, exposes only `127.0.0.1:8000`, and mounts host deployment data read-only (`/data:ro`).

---

## 8. Limitations

- **Local PC Deployment Target**: Currently deploys only to the developer's Windows PC via Docker Desktop and a self-hosted runner. **AWS EC2 and Nginx were NOT implemented**.
- **Single-Host Uptime Dependency**: The service is only online when the developer's Windows PC, Docker Desktop, and `Runner.Listener.exe` are running.
- **No TLS / Domain Routing**: Served over plain HTTP on `127.0.0.1:8000` without an Nginx reverse proxy or SSL certificate.
- **Stop-and-Replace Cutover**: Stopping the existing container before starting the new one causes brief downtime during updates.

---

## 9. Future Scope

- **AWS EC2 Cloud Hosting**: Provision a Linux EC2 instance (with Elastic IP and Security Groups) as the production deployment target.
- **Nginx Reverse Proxy & HTTPS**: Place Nginx in front of Gunicorn on ports 80/443 with Let's Encrypt TLS certificates.
- **Deployment History Dashboard**: Add a dedicated UI page in Flask listing historical deployments, commit links, and error messages.
- **Telegram Notifications**: Send instant deployment success, failure, and rollback alerts to a Telegram bot/channel.
- **Blue-Green Zero-Downtime Deployment**: Run old and new containers simultaneously behind Nginx and switch upstream traffic only after health checks pass.

---

## 10. Viva Questions & Answers (20 Q&As)

**1. What is the difference between CI and CD?**  
Continuous Integration (CI) automatically runs tests and builds/verifies artifacts whenever code is pushed (`test` + `build-and-push` jobs). Continuous Deployment (CD) automatically delivers that verified artifact to the target environment (`deploy` job) without manual intervention.

**2. Why use Docker containers instead of a Virtual Machine (VM)?**  
A VM virtualizes hardware and runs a full guest OS (heavy RAM/disk, slow boot). Docker containers share the host Linux kernel while isolating processes, libraries, and filesystems—making images small, portable, and fast to start in seconds.

**3. Why shouldn't deployments rely only on the `:latest` image tag?**  
`:latest` is mutable and overwritten on every push. If `:latest` is broken, rolling back to `:latest` would redeploy the broken code. Tagging every build with `${{ github.sha }}` creates immutable releases so `deploy.ps1` can pinpoint and restore the exact previous good build.

**4. How does AutoDeploy perform an automatic rollback?**  
Before touching the running container, `deploy.ps1` records the current container's image reference and `last_good_tag.txt`. If pulling, starting, or verifying the new container fails within 60 seconds, it deletes the failed container, starts the previous image again without failure flags, verifies it becomes healthy, logs `"rolled_back"` and `"failed"`, and exits with code `1`.

**5. Why verify `/version` commit SHA in addition to `/health`?**  
`/health` returning HTTP `200` only proves *some* copy of the app is running—for example, if a pull or container replacement silently failed and the old container remained up. Checking `/version` confirms the live process actually matches the newly pushed `commit_sha`.

**6. What does Docker's `HEALTHCHECK` do, and why did `Dockerfile` use Python `urllib` instead of `curl`?**  
Docker periodically runs the `HEALTHCHECK` command inside the container to mark it `healthy` or `unhealthy`. The `python:3.13-slim` base image does not include `curl` by default, so using Python's built-in `urllib.request` avoids installing extra packages and keeps the image minimal.

**7. What is a self-hosted GitHub Actions runner, and why was one used here?**  
A self-hosted runner is an agent (`Runner.Listener.exe`) installed on your own machine that polls GitHub for jobs labeled `runs-on: self-hosted`. It was used here so GitHub Actions can trigger deployments directly on the local Windows PC and Docker Desktop without opening inbound firewall ports or using SSH tunnels.

**8. What is the security risk of a self-hosted runner on a public repository, and how is it mitigated here?**  
On a public repo, anyone can fork the code and open a Pull Request. If a workflow uses `on: pull_request`, malicious PR code could run directly on your PC. AutoDeploy mitigates this by allowing only `push` (to protected `main`) and manual `workflow_dispatch` triggers—never `pull_request`.

**9. What is `GITHUB_TOKEN` and why is no external secret needed?**  
`GITHUB_TOKEN` is an automatically generated, short-lived installation token provided by GitHub Actions for each workflow run. With `packages: write` in `build-and-push`, it authenticates pushes to `ghcr.io`. Because our GHCR package is public, the `deploy` job only needs `contents: read` and no token at all to run `docker pull`.

**10. Why does the `deploy` job use `concurrency: autodeploy-deploy` with `cancel-in-progress: false`?**  
Two concurrent deployments editing the same `autodeploy-app` container, `deployment_history.json`, and `last_good_tag.txt` would cause race conditions. Setting `cancel-in-progress: false` queues new deployments cleanly rather than killing an active deployment mid-rollback.

**11. Why run the container as non-root `appuser` (UID `10001`)?**  
Running processes as `root` inside a container increases impact if the application is compromised. Using a dedicated non-root user follows the principle of least privilege.

**12. Why is `%USERPROFILE%\autodeploy-data` mounted read-only (`/data:ro`) into the container?**  
The Flask app only needs to *read* `deployment_history.json` to show status on `/`. Mounting `/data` read-only prevents the web container from modifying or corrupting its own audit logs. Only `deploy.ps1` on the host writes to that file.

**13. Why is port `8000` bound to `127.0.0.1:8000:8000` instead of `8000:8000`?**  
Binding to `127.0.0.1` restricts access strictly to localhost on the Windows PC rather than exposing an unencrypted HTTP server to the entire local network or public interfaces.

**14. Why use Gunicorn in Docker instead of Flask's built-in development server (`flask run`)?**  
Flask's built-in server is single-threaded and intended only for local debugging. Gunicorn is a production WSGI server capable of managing multiple worker processes (`--workers 2`), graceful signal handling, and concurrent HTTP requests.

**15. Why copy `requirements.txt` and run `pip install` before `COPY app/ ./app/` in `Dockerfile`?**  
Docker caches each instruction layer. Python dependencies change rarely compared to application code. Installing dependencies before copying `app/` lets Docker reuse the cached dependency layer on almost every build, making CI builds much faster.

**16. What is the difference between `ARG` and `ENV` in `Dockerfile`?**  
`ARG` variables exist only during `docker build` (e.g., passing `GIT_COMMIT_SHA`). `ENV` variables persist inside the running container. AutoDeploy converts `ARG` values into `ENV` variables so Flask's `Config` reads the baked-in commit SHA, build time, and version at runtime.

**17. Why did `pytest` in CI fail when `APP_VERSION` was changed to `1.1.0`, and how was it fixed?**  
`test_app_starts_and_creates_without_error` calls `create_app()` with no overrides and asserts default `APP_VERSION == "1.0.0"`. Setting `APP_VERSION: "1.1.0"` at the workflow level passed that variable into the `test` job. Running `env -u APP_VERSION pytest -v` unset it during unit tests while keeping `1.1.0` for container builds.

**18. What is the `[simulate-failure]` mechanism used for?**  
Putting `[simulate-failure]` in a commit message sets `SIMULATE_FAILURE=true` in `deploy.ps1`, which overrides the container entrypoint with `sleep 3600`. Because Gunicorn never starts, Docker marks the container `unhealthy`, safely proving the rollback pipeline works end-to-end without breaking `app/` code.

**19. Why does `deploy.ps1` write `deployment_history.json` using UTF-8 without BOM?**  
PowerShell 5.1's default UTF-8 encoding prepends a 3-byte Byte Order Mark (BOM, `\xef\xbb\xbf`). Python's `json.loads()` on files opened with `encoding="utf-8"` fails on a leading BOM, so `deploy.ps1` explicitly uses `System.Text.UTF8Encoding($false)` to guarantee valid JSON for Flask.

**20. What happens if `deployment_history.json` is missing, empty, or corrupted?**  
`load_deployment_status()` in `app/app.py` checks file existence, handles empty content, wraps `json.loads()` in a `try/except`, and falls back safely to `"No deployment history yet"` instead of crashing the `/` route.
