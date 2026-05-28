# Miaotao GO All Videos IPA

This repo rebuilds `miaotaoGOm0492_303_fixed.ipa` so the dynamic red-match video endpoint loads all videos from the Cloudflare Worker API.

- Original endpoint: `https://api.jlyapp.cn/vip1/meet-list`
- Patched endpoint: `https://all.jlyapp.cn/vip1/meet-list`
- Output IPA: `dist/miaotaoGOm0492_303_all_videos.ipa`

## Build

```bash
npm run build
npm run verify
```

GitHub Actions runs the same build on macOS and uploads the IPA artifact.
