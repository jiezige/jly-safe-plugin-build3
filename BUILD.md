# Build and deploy

## What this changes

- Patches `cike.dylib` in the IPA from `api.jlyapp.cn` and `stz.jlyapp.cn` to `pee.jlyapp.cn`, matching the APK host.
- Does not modify the `pee-jlyapp` project code.
- Adds a Cloudflare Worker in front of the APK-compatible `pee.jlyapp.cn` routes used by the IPA patch:
  `/app-update.json`, `/vip1*`, and `/api/posts/*`.
- The IPA patch repoints the paid video list request from `/api/posts/app-list` to `/api/posts/all-app-list`, matching the APK all-video endpoint while keeping the original `app-list` string in the binary.
- The macOS build embeds `JLYSearchAddon.dylib`, which adds a search button to the paid video list and appends `q=<keyword or id>` to the `all-app-list` request.
- `/vip1`, `/vip1/activate`, `/vip1/meet-list`, `/vip1/online-request`, `/api/posts/ingest-response`, and `/app-update.json` are proxied without response filtering.
- The Worker supports fuzzy search parameters: `q`, `search`, `keyword`, `id`, `title`, `name`.
- If `JLY_TOKEN` is not configured, the Worker falls back to the APK token embedded in `all-app-list`.

## Cloudflare Worker

Set these GitHub repository secrets before running the deploy workflow:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN`

If the upstream needs a fixed token, set this Worker secret:

```bash
npx wrangler secret put JLY_TOKEN
```

Test examples after deployment:

```bash
curl "https://pee.jlyapp.cn/api/posts/app-list?q=123"
curl "https://pee.jlyapp.cn/api/posts/all-app-list?q=test"
```

## GitHub Actions IPA build

Run the `Build patched IPA` workflow. It outputs:

```text
dist/miaotaoGOm0492_303_cf.ipa
```

For normal iOS device installation, configure signing secrets:

- `SIGNING_CERT_P12_BASE64`
- `SIGNING_CERT_PASSWORD`
- `MOBILEPROVISION_BASE64`
- `CODESIGN_IDENTITY`

Without those signing secrets, the workflow uses ad-hoc signing. That is usually only useful for jailbreak or special install environments.

## Local patch only

```bash
python3 scripts/patch_ipa.py miaotaoGOm0492_303_fixed.ipa dist/miaotaoGOm0492_303_cf_unsigned.ipa
```

This local output has the endpoint host patched, but it is not validly re-signed for normal iOS installation.
