# remote-compile-assets-heroku-buildpack

Heroku buildpack that triggers an app compilation remotely by calling a webhook on CI.

## How it works

The buildpack runs **twice** per Heroku build (configured via two entries in the app's
buildpack list):

| Pass | `CURRENT_BUILDPACK_STEP` | What happens |
|------|--------------------------|---------------|
| 1 | *(unset)* | Triggers a Harness webhook to compile frontend assets and upload them to S3/CDN. Writes a bogus asset manifest so the Ruby buildpack skips `assets:precompile`. |
| 2 | `download_manifest` | Polls the CDN until `manifests.tar.gz` and `finished.txt` appear, then extracts the manifests. Applies S3 retention tags and updates the local SHA cache. |

## CDN asset retention policy (FLOW-963)

After each deploy the Harness pipeline uploads new Vite assets to S3 under a
`/{commit_sha}/vite/assets/…` prefix and then prunes the previous commit SHA’s
directory.  When a user has an older HTML page cached in their browser and
navigates to a new route after a deploy, Vite tries to lazy-load CSS chunks from
the *prior* commit SHA’s CDN path — which no longer exists, producing:

```
Unable to preload CSS for //d3ba1hutuxgydn.cloudfront.net/{old_sha}/vite/assets/Router-KNKeKozn.css
```

### How this buildpack addresses the problem

#### 1. `retainShas` webhook payload field

Every time the buildpack fires the Harness webhook it now includes a
`retainShas` array containing the **two most recent prior deploy SHAs**
(persisted in `CACHE_DIR/retain_shas` across builds):

```json
{
  "commitSha": "<current-sha>",
  "branch":    "master",
  "env":       "PRODUCTION",
  "retainShas": ["<sha-n-1>", "<sha-n-2>"]
}
```

The Harness pipeline **must be updated** to skip deleting S3 prefixes whose SHA
appears in `retainShas`.  This is the primary guard against rapid back-to-back
deploys where both prior asset sets may be less than 24 hours old.

#### 2. S3 object tagging (belt-and-suspenders)

After a successful upload, the buildpack optionally tags every object under the
current and immediately-prior SHA prefix with `retain=permanent`.  It removes
that tag from any older prefixes recorded in the cache.  This requires:

| Environment variable | Description |
|----------------------|-------------|
| `CDN_ASSETS_S3_BUCKET` | Name of the S3 bucket that holds the Vite assets |
| `AWS_ACCESS_KEY_ID` | AWS credentials with `s3:PutObjectTagging`, `s3:DeleteObjectTagging`, and `s3:ListObjectsV2` on the bucket |
| `AWS_SECRET_ACCESS_KEY` | |
| `AWS_DEFAULT_REGION` | Region of the bucket |

If `CDN_ASSETS_S3_BUCKET` is not set or the AWS CLI is not on `PATH` the step
skips gracefully and logs a warning.

#### 3. Required S3 lifecycle rule

Configure an S3 lifecycle rule on the bucket so that **untagged** old prefixes
are expired automatically:

```json
{
  "Rules": [
    {
      "ID": "expire-old-vite-assets",
      "Status": "Enabled",
      "Filter": {
        "And": {
          "Prefix": "",
          "Tags": []
        }
      },
      "Expiration": { "Days": 2 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 1 }
    }
  ]
}
```

> **Important:** The expiration filter must **exclude** objects tagged with
> `retain=permanent`.  In the AWS Console, set the filter to
> *"Objects without the tag: retain=permanent"*, or use an
> [object tag filter](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-configuration-examples.html#lifecycle-config-ex9)
> that only applies the rule to objects whose `retain` tag value is **not**
> `permanent`.
>
> A simpler alternative: remove the Harness prune step entirely and apply a
> 30-day lifecycle rule with no tag filter.  Storage cost is negligible
> (~$1–2 / month at typical deploy cadence).

#### 4. CloudFront 4xx TTL

Verify that your CloudFront distribution does **not** cache 4xx responses for
asset paths.  A cached 404 would persist at the edge even after the retention
policy re-protects the underlying S3 object.

Recommended CloudFront cache behaviour for `/{sha}/vite/assets/*`:

| Setting | Recommended value |
|---------|-------------------|
| Cache successful responses (`200`) | `31536000` s (1 year — assets are content-hashed) |
| Cache 4xx responses | `0` s (do **not** cache errors) |
| Cache 5xx responses | `0` s |

In Terraform / CloudFormation this corresponds to `error_caching_min_ttl = 0`
on the distribution’s custom error responses.

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CDN_HOST` | ✅ | — | Hostname of the CDN (e.g. `d3ba1hutuxgydn.cloudfront.net`) |
| `RAILS_ENV` | ✅ | — | Rails environment (`production`, `staging`, …) |
| `CDN_ENV` | ❌ | `$RAILS_ENV` | Override the env label sent to Harness |
| `REMOTE_BUILD_TIMEOUT_MINUTES` | ❌ | `10` | Max minutes to wait for the remote build |
| `HARNESS_WEBHOOK_BASE_URL` | ✅ | — | Harness webhook base URL |
| `HARNESS_ACCOUNT_IDENTIFIER` | ✅ | — | Harness account ID |
| `HARNESS_ORG_IDENTIFIER` | ✅ | — | Harness org ID |
| `HARNESS_PROJECT_IDENTIFIER` | ✅ | — | Harness project ID |
| `HARNESS_PIPELINE_IDENTIFIER` | ✅ | — | Harness pipeline ID |
| `HARNESS_TRIGGER_IDENTIFIER` | ✅ | — | Harness trigger ID |
| `CDN_ASSETS_S3_BUCKET` | ❌ | — | S3 bucket name; enables S3 retention tagging when set |
| `AWS_ACCESS_KEY_ID` | ❌ | — | Required when `CDN_ASSETS_S3_BUCKET` is set |
| `AWS_SECRET_ACCESS_KEY` | ❌ | — | Required when `CDN_ASSETS_S3_BUCKET` is set |
| `AWS_DEFAULT_REGION` | ❌ | — | Required when `CDN_ASSETS_S3_BUCKET` is set |
