# remote-compile-assets-heroku-buildpack

A Heroku buildpack that offloads frontend asset compilation to a remote CI pipeline (Harness), then downloads the compiled artifacts during a subsequent Heroku build step — keeping Heroku dynos free of Node/Webpack toolchains and dramatically speeding up deploys.

---

## How it works

The buildpack is designed to run **twice** in a single Heroku build, by being added to your app's buildpack list two times. The two invocations each handle a different phase:

### Step 1 — Trigger remote compilation

1. Checks the CDN for a `finished.txt` marker at `https://<CDN_HOST>/<COMMIT_SHA>/finished.txt`.
   - If the marker already exists (i.e. a previous remote build produced assets for this exact commit), it skips triggering a new pipeline run.
   - Otherwise it fires a POST webhook to a Harness pipeline trigger to kick off asset compilation remotely.
2. Writes a bogus `public/assets/manifest-*.json` file so that the Ruby buildpack (which runs between the two invocations of this buildpack) does **not** call `assets:precompile`.
3. Deletes `package.json` and `yarn.lock` from the build directory so the Ruby buildpack does not attempt to install Node.js.
4. Writes the current commit SHA to `HEROKU_BUILD_COMMIT` in the build directory to support freshly-created review apps that lack the Heroku Labs feature providing `SOURCE_VERSION`.
5. Sets `CURRENT_BUILDPACK_STEP=download_manifest` in the buildpack's `export` file so the second invocation knows to enter Step 2.

### Step 2 — Download compiled assets

1. Polls `https://<CDN_HOST>/<COMMIT_SHA>/manifests.tar.gz` at a configurable interval until the file appears, or until the timeout is reached.
2. Extracts the manifest archive into `$BUILD_DIR/public/`.
3. Continues polling for `finished.txt` to confirm all compiled assets have been fully uploaded before letting the build proceed.

---

## Setup

### 1. Add the buildpack twice

The buildpack must appear **before** the Ruby buildpack on the first addition, and **after** it on the second:

```
1. https://github.com/oysterhr/remote-compile-assets-heroku-buildpack  ← Step 1
2. heroku/ruby
3. https://github.com/oysterhr/remote-compile-assets-heroku-buildpack  ← Step 2
```

Using the Heroku CLI:

```bash
heroku buildpacks:add --index 1 https://github.com/oysterhr/remote-compile-assets-heroku-buildpack --app YOUR_APP
heroku buildpacks:add https://github.com/oysterhr/remote-compile-assets-heroku-buildpack --app YOUR_APP
```

### 2. Configure environment variables

Set the following config vars on your Heroku app:

#### Required

| Variable | Description |
|---|---|
| `CDN_HOST` | Hostname of the CDN bucket where compiled assets are stored (e.g. `assets.example.com`). |
| `HARNESS_WEBHOOK_BASE_URL` | Base URL of the Harness pipeline webhook endpoint. |
| `HARNESS_ACCOUNT_IDENTIFIER` | Harness account identifier. |
| `HARNESS_ORG_IDENTIFIER` | Harness organisation identifier. |
| `HARNESS_PROJECT_IDENTIFIER` | Harness project identifier. |
| `HARNESS_PIPELINE_IDENTIFIER` | Harness pipeline identifier. |
| `HARNESS_TRIGGER_IDENTIFIER` | Harness trigger identifier. |

#### Optional

| Variable | Default | Description |
|---|---|---|
| `REMOTE_BUILD_TIMEOUT_MINUTES` | `10` | Maximum number of minutes to wait for the remote build to finish before aborting. |
| `CDN_ENV` | Value of `RAILS_ENV` | Environment label passed to the Harness pipeline (uppercased). Useful when CDN paths differ from the Rails environment name. |

---

## Webhook payload

When a new remote build is triggered, the following JSON body is sent to the Harness webhook:

```json
{
  "commitSha": "<SOURCE_VERSION>",
  "branch": "master",
  "env": "<CDN_ENV>"
}
```

---

## CDN directory structure expected

The buildpack expects the remote CI pipeline to upload assets to a path rooted at the commit SHA:

```
https://<CDN_HOST>/<COMMIT_SHA>/
  manifests.tar.gz   ← tar archive of asset manifest files
  finished.txt       ← sentinel file written last, signals completion
```

---

## Local development / testing

The `test/env/` directory contains sample env-file stubs used when running the buildpack scripts locally. To test manually:

```bash
export BUILD_DIR=$(mktemp -d)
export CACHE_DIR=$(mktemp -d)
export ENV_DIR=$(pwd)/test/env
export SOURCE_VERSION=<a-commit-sha>

bash bin/compile "$BUILD_DIR" "$CACHE_DIR" "$ENV_DIR"
```
