# Stapleton IQ website

The hosted version of the unit setup page and the live dashboard.
Plain HTML and JavaScript, no build step. Every push to `main` deploys automatically (Vercel).

| Address | What it is |
|---|---|
| `/` | Home: links, list of units, install-to-home-screen hint |
| `/dashboard` | Live checkpoint counts (staff see all events, clients see their own) |
| `/setup` | Unit setup (camera photo, counting lines, ignore zones, line zones for wait times, reset to zero). Staff only |
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
- `pi/`: the counting software on the units (`counter.py`, `iq_uploader.py`). Not part of the website
  (`.vercelignore` keeps `pi/` and `supabase/` off the site); copied to each Pi by hand.
- `supabase/`: database functions. `iq_wait_time.sql` adds wait-time estimates (below)

## Wait-time estimates (back end only, not on the dashboard yet)

On the setup page, tick **Line zone** and drag the blue box over where people stand in line.
Every frame the unit counts the people inside that box and, once a minute, sends the average
and the most it saw (`queue_samples`, via `ingest_queue`). The counting line at the same
checkpoint gives people through per minute (last 5 minutes), and

    estimated wait (minutes) = people in line / people through per minute

`iq_wait_times(event_id)` returns this per checkpoint per minute; `web_wait_times(event_id)` is
the staff-only version for the website later. A second unit can be set to
**Watches the line only**: it sends line counts and no crossings; assign it to the same
checkpoint as the unit that counts. Draw line zones so two units don't cover the same people.
A unit with no line zone behaves exactly as before.
