# User interface guide

The front end is plain HTML, CSS and JavaScript in `web/`. There is no build step and no framework.
FastAPI serves the folder, so `/` is the landing page and the app screens sit beside it.

## Pages

| URL | Purpose | Files |
| --- | --- | --- |
| `/` | Landing page | `web/index.html`, `shared/site.css` |
| `/login/` | One sign-in and sign-up form for everyone | `web/login/index.html`, `app.js` |
| `/rider/` | Wallet, QR pass, M-Pesa top-up, activity | `web/rider/` |
| `/operator/` | Revenue, demand, suspicious trips, payouts | `web/operator/` |
| `/validator/` | Gate scanner with offline queue | `web/validator/` (also `sw.js`) |
| shared | Theme, API helper and session, icons and chart | `web/shared/theme.css`, `api.js`, `ui.js` |

## Sign-in routing (nothing about account types is shown on the form)

The form has two fields, "Account" and "Passcode". What is typed decides the destination.

| Typed in Account | Passcode | Tried against | Lands on |
| --- | --- | --- | --- |
| A phone number | PIN | `POST /auth/login` | `/rider/` |
| Anything else | Password | `POST /auth/operator/login` | `/operator/` |
| Anything else, or the operator step failed | (empty) | `GET /validator/config` with the value as the device key | `/validator/` |

- Every failed attempt shows the same message, so the screen never reveals which kinds of account exist.
- "Create an account" is for riders only (`POST /auth/register`).
- The result is stored as one `tl_session` in `localStorage`: `{role, token | key, name}`.
- Each protected page calls `Session.require('<role>')` first. Signed-out visitors go to `/login/`; someone
  with the wrong role is sent to their own screen.

Demo logins for the team (they are deliberately not shown anywhere in the UI):

| Who | Account | Passcode |
| --- | --- | --- |
| Rider | 0712 345 678 | 1234 |
| Rider with history | 0700 000 000 | 0000 |
| Operator | rail | demo1234 |
| Operator (feeder) | sacco | demo1234 |
| Gate device | demo-validator-key-1 | (leave empty) |

A device key works like a password: anyone who has it can sign in as that device. Issue real keys per
device and rotate them if a device is lost.

## Design system

Taken from the supplied reference: dark green backdrop, lime `#DCFFAD`, white `#FFFFFF`, sage `#7B9575`,
ink `#1C2120`, SF Pro Display (falls back to the system font on devices without it), hatched fills,
a floating pill navigation and round icon buttons. All tokens are CSS variables at the top of
`shared/theme.css`.

| Piece | Where |
| --- | --- |
| Buttons (`btn-white`, `btn-lime`, `btn-black`, `btn-ghost`, `icon-btn`) | `theme.css` |
| Cards (`card-white`, `card-lime`, `card-glass`, `card-dark`), tiles | `theme.css` |
| Hatched bar chart with one solid bar and a white tooltip | `ui.js` `barChart()`, bar styles in `theme.css` |
| Hatched progress meter (QR countdown, boarding points) | `.meter` in `theme.css` |
| Icons and the seven-point brand star | `ui.js` (`icon()`, `star()`, `mountIcons()`) |

## Responsive behaviour

- Phones: one view at a time, switched with the floating pill nav (`.view.active`).
- From 1000px wide: the pill nav hides and every view shows at once as a two-column dashboard.
  Round action buttons then scroll to the matching section instead of switching views.
- The layout has been checked for horizontal overflow at 320, 390, 768 and 1280px wide.

## Notes and limits

- The QR pass uses `qrcodejs` and the scanner uses `jsQR`, both loaded from the jsDelivr CDN with pinned versions.
  Open the validator once online so its service worker can cache the scanner for offline use.
- The rider chart is built from the latest 30 wallet entries returned by `GET /wallet`, so very busy
  accounts may show a partial week.
- The camera needs HTTPS or `localhost`.
- Absolute paths such as `/login/` assume the app is served from the site root.
- Sessions are kept in `localStorage` and there is no login throttling yet (see `docs/DEPLOY.md`).
