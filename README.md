# remote-compile-assets-heroku-buildpack

Heroku buildpack that triggers an app compilation remotely by calling a webhook on CI.

## How it works

The buildpack runs twice per Heroku build (two buildpack slots):

1. **Step 1** — Triggers a Harness webhook to compile frontend assets and upload them to S3/CDN. Creates a bogus manifest file so the Ruby buildpack skips `assets:precompile`, and removes `package.json`/`yarn.lock` so the Ruby buildpack does not install Node.
2. **Step 2** (`CURRENT_BUILDPACK_STEP=download_manifest`) — Polls the CDN until `manifests.tar.gz` is available, extracts it, and waits for `finished.txt` to confirm all assets have been uploaded. Runs the CDN asset retention policy once the upload is confirmed.

## CDN Asset Retention Policy (FLOW-963)

After each production deploy, Vite assets are uploaded to S3 under a new commit-SHA-prefixed path (`/{sha}/vite/assets/...`). Users who have an older HTML page cached in their browser will try to lazy-load CSS/JS from the *previous* deploy's CDN path after navigating to a new route. If those files have been deleted, the browser throws:

```
Unable to preload CSS for //{cdn_host}/{old_sha}/vite/assets/Router-xxx.css
```

To prevent this, the buildpack now applies a **tag-based retention policy** via `bin/retain_cdn_assets`:

- The **two most-recent** deploy prefixes are left untagged (protected indefinitely).
- **Older** deploy prefixes have their objects tagged `expirable=true`.
- An **S3 lifecycle rule** (see [`lifecycle/s3-lifecycle-policy.json`](lifecycle/s3-lifecycle-policy.json)) expires objects tagged `expirable=true` after **24 hours**.

This guarantees that users with a cached page from deploy N−1 can still load assets after deploy N completes, while old assets are cleaned up automatically.

### Required Heroku config vars

| Variable | Description |
|---|---|
| `CDN_HOST` | CloudFront hostname (existing) |
| `S3_BUCKET` | S3 bucket backing the CDN (e.g. `oyster-assets-prod`) |
| `AWS_ACCESS_KEY_ID` | AWS credentials with `s3:ListBucket`, `s3:GetObjectTagging`, `s3:PutObjectTagging` |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials (secret) |
| `AWS_DEFAULT_REGION` | AWS region (default: `us-east-1`) |
| `HARNESS_WEBHOOK_BASE_URL` | Harness webhook URL (existing) |
| `HARNESS_ACCOUNT_IDENTIFIER` | Harness identifiers (existing) |
| `HARNESS_ORG_IDENTIFIER` | Harness identifiers (existing) |
| `HARNESS_PROJECT_IDENTIFIER` | Harness identifiers (existing) |
| `HARNESS_PIPELINE_IDENTIFIER` | Harness identifiers (existing) |
| `HARNESS_TRIGGER_IDENTIFIER` | Harness identifiers (existing) |

### Optional Heroku config vars

| Variable | Default | Description |
|---|---|---|
| `S3_ASSETS_PREFIX` | lower-case `CDN_ENV`/`RAILS_ENV` | Path prefix inside the bucket where SHA directories live |
| `RETAIN_DEPLOY_COUNT` | `2` | Number of most-recent deploys to protect from expiry |
| `REMOTE_BUILD_TIMEOUT_MINUTES` | `10` | Max wait time for the remote build |

### One-time S3 lifecycle rule setup

Apply the bundled policy to your S3 bucket once:

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket <your-s3-bucket> \
  --lifecycle-configuration file://lifecycle/s3-lifecycle-policy.json
```

Objects tagged `expirable=true` will be deleted by S3 after 1 day. Objects without that tag are never touched by the lifecycle rule.

### Required Harness pipeline change

> ⚠️ **Remove the prune step from the Harness pipeline.**

The `aws s3 rm --recursive` or `aws s3 sync --delete` call that deletes the previous commit SHA's directory must be removed from the Harness asset-upload pipeline. The `retain_cdn_assets` script now owns cleanup via the S3 lifecycle rule — the manual prune is no longer needed and is the root cause of the preload errors.

### CloudFront 4xx caching

Verify that your CloudFront distribution is **not caching 4xx responses** for asset paths. A cached 404 at the edge would persist even after the lifecycle policy protects the underlying S3 object. In your CloudFront cache behaviour for `/*/vite/assets/*`, confirm:

- **Error caching minimum TTL** for 4xx responses is set to **0 seconds** (or as low as possible).
- Alternatively, create a custom error response rule in the distribution that sets a 0-second TTL for 403/404 responses.
