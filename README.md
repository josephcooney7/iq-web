# Stapleton IQ website

The hosted version of the unit setup page and the live dashboard.
Plain HTML and JavaScript, no build step. Every push to `main` deploys automatically (Vercel).

| Address | What it is |
|---|---|
| `/` | Home: links, list of units, install-to-home-screen hint |
| `/dashboard` | Live checkpoint counts (admin/manager see all events, clients see their own) |
| `/client` | Client view: what a client sees for an event (live counts, security wait times, next-morning report, all events) plus the incident report form and a "View as client" switch. Admin and manager only for now |
| `/setup` | Unit setup (camera photo, counting lines, ignore zones, reset to zero). Staff only |
| `/u/IQ-01` | Opens unit setup straight to that unit. This is what the QR stickers point at |
| `/stickers` | Printable QR stickers for every active unit |
| `/gear` | Equipment: where every unit is, load-out check (what's still missing from an event) |
| `/g/OG-49000` | Opens sign-out / return for that piece of equipment. This is what the equipment QR stickers point at |
| `/gear-sheet?event=...` | Printable sign-out sheet for one event, laid out like the paper form (print or save as PDF) |
| `/gear-stickers` | Printable QR stickers for every piece of equipment |

## How it fits together

- Login is Supabase Auth (email + password). Access comes from `public.profiles.role`:
  `admin` and `manager` can do everything; `field_tech` (Field Tech) gets the Equipment pages only;
  `client` sees only its own client's dashboards.
  A new login has no access until a profile row is added.
- Pages only call the database functions in `supabase/iq_web_app_functions.sql`
  (`web_me`, `web_units`, `web_unit_lines`, `web_dashboard`) and `supabase/iq_equipment.sql` + `iq_equipment_2.sql`
  (`web_gear_item`, `web_gear_save`, `web_gear_move`, `web_gear_list`, `web_gear_history`, `web_gear_photo`)
  and `supabase/iq_roles_client_view.sql` (`web_client_view`, `web_incident_save`, `web_incident_share`, `web_incident_photo`). Each checks the user's role.
- Equipment sign-outs are never edited or deleted. Who and when come from the login and the server clock.
- The key in `js/app.js` is Supabase's publishable key, which is meant to be in web pages.
- The Pi units are unchanged: they still talk to Supabase with their own device keys.

## Files

- `index.html`, `dashboard.html`, `setup.html`, `stickers.html`, `client.html`: the pages
- `gear.html`, `scan.html`, `gear-sheet.html`, `gear-stickers.html`, `js/gear.js`, `css/gear.css`: equipment sign-out
- `js/app.js`: shared login screen, top bar, database helper
- `css/common.css`: shared colours and login styles
- `js/supabase.js` (supabase-js 2.45.4), `js/qrcode.js` (qrcode-generator 1.4.4): vendored libraries
- `manifest.webmanifest`, `sw.js`, `icons/`: home-screen install
- `vercel.json`: clean URLs and the `/u/<unit>` route
