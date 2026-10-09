# Transparent logo

## Objective
The owner asked to replace the CRM logo with one that has a transparent background and supplied the artwork `logoOsmanyServiceTrnsparente.png` (2000x2000 RGBA). The monogram was cropped to its bounding box, padded 4%, and exported as `public/logo-mark.png` (512x512 RGBA). `BrandMark` now uses `object-contain` and no longer clips the image with its own rounded corners. It is used in the sidebar and in the login / signup / forgot-password screens.

## Not changed
- `public/logo-full.png` keeps its dark background (owner decision pending).
- `src/app/icon.png` (browser-tab icon) was not part of commit f8fa6b4; it was converted afterwards in commit 4012a1b, which is NOT in the staging release below. Whether the tab icon should be transparent too remains an owner decision.
- The login screen still passes `rounded-xl` to `BrandMark`; harmless on a transparent image, left as is.

## Evidence
- Staging deploy (2026-10-09; release f8fa6b43e63997ff188fecb7aeba1599187908dc, BUILD_ID hTo5czz3XQFDRxRrXGhGr, app commit f8fa6b4): manifest environment=staging, project kolppplawzdsjfydwejr, 0 production refs, 32 files with staging refs, 114 build tests passed, sha256 OK on oracle2, fresh extraction 2477 files laid out like the previous release, pm2 wacrm-staging cwd resolves to the new release, restarts 93 -> 94 and stable (unstable 0), /login 200 with "Bienvenido de nuevo" and the new BUILD_ID, `https://crm.onlinefreedom.site/logo-mark.png` byte-identical (sha256 a7299f87...6002f) to `public/logo-mark.png` of f8fa6b4 and a 512x512 RGBA PNG, the forgot-password HTML references the logo through `/_next/image?url=%2Flogo-mark.png&w=96&q=75` (login and signup render it client-side), and that optimizer URL returns 200 as image/webp with alpha (96x96 and 48x48) or image/png when no webp is accepted. Rollback: anterior -> 26725abc35abc2bb0324425e5ade2f7c148c4d5f (`ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/26725abc35abc2bb0324425e5ade2f7c148c4d5f ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`).
