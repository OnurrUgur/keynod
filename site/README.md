# Keynod landing page

Static site, no build step, no framework, no external hosts. Everything it loads lives in this folder.

## Preview

```bash
cd site
/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1
# open http://127.0.0.1:8765/
```

## Before publishing

1. **Repository URL.** Change `REPO_URL` at the top of `assets/js/site.js`. Every GitHub link and the `git clone` line are filled from it. (The clone line in `index.html` carries the same URL as a no-JavaScript fallback; update it too if you want that fallback exact.)
2. **Absolute social image.** Open Graph and X/Twitter want absolute URLs. Once the domain is known, change `og:image` and `twitter:image` in `index.html` to `https://<domain>/assets/og.png` and add `<meta property="og:url" content="https://<domain>/">` plus `<link rel="canonical" href="https://<domain>/">`.
3. **Content-Security-Policy.** The page has no inline scripts, inline styles or event handlers, so this works:
   `default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`
   Also send `X-Content-Type-Options: nosniff`.
4. **Facts.** The comparison table covers Keynod alongside the 1Password CLI, `.env` files and pasting keys into chat. Re-check the 1Password CLI row against its current docs before launch.

## Files

- `index.html`: the page.
- `assets/css/site.css`, `assets/js/site.js`: all styling and behaviour (hero loop, demo terminal, tabs, copy buttons, marquee). `prefers-reduced-motion` stops every loop and shows the final frames.
- `assets/svg/keynod-robot.svg`: the mascot without its tile, taken from `docs/icon.svg`. The hero inlines the same artwork so CSS can animate the nod and eyes.
- `assets/svg/keynod-icon.svg`: copy of `docs/icon.svg`, used as favicon and app icon.
- `assets/og.png`: 1200x630 social image, rendered from HTML with headless Chrome.
- `assets/fonts/`: Geist and Geist Mono variable fonts from the `geist` npm package (v1.9.2), SIL Open Font License, see `OFL.txt`.
