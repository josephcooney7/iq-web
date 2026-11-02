# Stapleton IQ website

The hosted version of the unit setup page and the live dashboard.
Plain HTML and JavaScript, no build step. Every push to `main` deploys automatically (Vercel).

| Address | What it is |
|---|---|
| `/` | Home: links, list of units, install-to-home-screen hint |
| `/dashboard` | Live checkpoint counts (staff see all events, clients see their own) |
| `/setup` | Unit setup (camera photo, counting lines, ignore zones, reset to zero). Staff only |
| `/u/IQ-01` | Opens unit setup straight to that unit. This is what the QR stickers point at |
| `/stickers` | Printable QR stickers for every active unit |

## How it fits together

- Login is Supabase Auth (email + password). Access comes from `public.profiles.role`:
  `admin`, `manager`, `staff` can do everything; `client` sees only its own client's dashboards.
  A new login has no access until a profile row is added.
- Pages only call the database functions in `supabase/iq_web_app_functions.sql`
  (`web_me`, `web_units`, `web_unit_lines`, `web_dashboard`). Each checks the user's role.
- The key in `js/app.js` is Supabase's publishable key, which is meant to be in web pages.
- The Pi units are unchanged: they still talk to Supabase with their own device keys.

## Files

- `index.html`, `dashboard.html`, `setup.html`, `stickers.html`: the pages
- `js/app.js`: shared login screen, top bar, database helper
- `css/common.css`: shared colours and login styles
- `js/supabase.js` (supabase-js 2.45.4), `js/qrcode.js` (qrcode-generator 1.4.4): vendored libraries
- `manifest.webmanifest`, `sw.js`, `icons/`: home-screen install
- `vercel.json`: clean URLs and the `/u/<unit>` route
