# Inventory & Shipment API — Authentication

ASP.NET Core (.NET 10) Web API with a layered architecture and JWT-based login, plus a separate
React frontend.

```
Inventory_Shipment.slnx         Visual Studio solution (the four .NET projects below)
Inventory_Shipment.API          Web API: controllers, JWT setup, Scalar API docs
Inventory_Shipment.Service      Business logic: auth flow, Argon2id hashing, JWT issuing, password policy
Inventory_Shipment.Repository   Data access: Dapper + SQL Server, schema bootstrap
Inventory_Shipment.Model        Entities, DTOs, enums, options — shared, no dependencies
Database/                       SQL scripts to create the schema and seed the first admin in SSMS
```

The React frontend is a **separate folder next to this one**:

```
D:\VSProjects\Inventory_Shipment.Web    React + Vite + TypeScript frontend (login, dashboard, users) — open in VS Code
```

Open `D:\VSProjects\Inventory_Shipment.code-workspace` to get both folders in a single VS Code window.

## Run it

**API (Visual Studio)**

1. Open `Inventory_Shipment.slnx`, make **Inventory_Shipment.API** the startup project, press **F5** (or `dotnet run --project Inventory_Shipment.API`).
2. The browser opens the **Scalar API reference** at `https://localhost:7089/scalar/` where you can try every endpoint (use *Authorize* → Bearer with the `accessToken` from `POST /api/auth/login`).

**Frontend (VS Code)**

1. Open `D:\VSProjects\Inventory_Shipment.Web` in VS Code (or open `D:\VSProjects\Inventory_Shipment.code-workspace` for both folders at once).
2. `npm install` (first time), then `npm run dev` — or press **F5** in VS Code.
3. Browse to `http://localhost:5174` and sign in with the seeded account:

   | Username | Password |
   |----------|--------------|
   | `admin`  | `Admin@12345` |

   Change this password right after the first sign-in. The dev server proxies `/api` to the API, so keep the API running.

See `D:\VSProjects\Inventory_Shipment.Web\README.md` for details on the frontend.

On start-up the app connects to SQL Server, creates the `Inventory_Shipment` database if it is missing, applies the schema (tables `Users`, `RefreshTokens`, `LoginAudit`), and seeds the admin if the `Users` table is empty. So you normally don't need to run anything in SSMS — but the scripts in `Database/` do the same thing by hand if you prefer.

The connection string (in `appsettings.json`) points at `Server=.` with Windows Authentication:

```
Server=.;Database=Inventory_Shipment;Trusted_Connection=True;Encrypt=True;TrustServerCertificate=True;
```

If your SSMS server name is different (for example `.\SQLEXPRESS` or `(localdb)\MSSQLLocalDB`), change `ConnectionStrings:DefaultConnection` to match.

## API surface

Base path `/api`. Everything except login/refresh requires `Authorization: Bearer <accessToken>`.

| Method | Route | Auth | Purpose |
|--------|-------|------|---------|
| POST | `/api/auth/login` | anonymous | Sign in, returns access + refresh tokens |
| POST | `/api/auth/refresh` | anonymous | Rotate tokens using a refresh token |
| POST | `/api/auth/logout` | bearer | Revoke one refresh token |
| POST | `/api/auth/logout-all` | bearer | Revoke every session of the current user |
| GET  | `/api/auth/me` | bearer | Current user's profile |
| POST | `/api/auth/change-password` | bearer | Change own password |
| GET  | `/api/users` | Admin | List users |
| POST | `/api/users` | Admin | Create a user |
| GET  | `/api/users/{id}` | Admin | Get a user |
| PATCH | `/api/users/{id}/status` | Admin | Activate / deactivate |
| POST | `/api/users/{id}/reset-password` | Admin | Reset a user's password |

Interactive API docs (Development only): **`https://localhost:7089/scalar/`** — this is what F5 opens.
There is also `Inventory_Shipment.API.http` you can run request-by-request from Visual Studio.

## Security

- **Passwords**: hashed with **Argon2id** (RFC 9106, 64 MiB / 3 iterations / 4 lanes). Plaintext is never stored; parameters are embedded in the hash and upgraded automatically on next login if you raise them.
- **Tokens**: short-lived JWT access token (15 min, HMAC-SHA256) + long-lived refresh token (7 days). Only the **SHA-256 hash** of a refresh token is stored. Refresh **rotates** the token and **detects reuse** — presenting a revoked token invalidates the whole session family.
- **Lockout**: an account locks for 15 minutes after 5 failed attempts.
- **Enumeration-resistant**: unknown username and wrong password return the same message and take the same time.
- **Rate limiting**: login/refresh are limited per client IP (10 / minute by default).
- **Secure by default**: every endpoint requires authentication unless marked `[AllowAnonymous]`; role checks via `[Authorize]` policies. Security headers and audit logging (`LoginAudit`) are on.
- **Roles**: `Admin`, `Manager`, `User`.

## Configuration

`appsettings.json` holds non-secret defaults. `appsettings.Development.json` carries development-only values so F5 works out of the box, including:

- `Jwt:SecretKey` — the token signing key (a development key is provided; use a new 32+ char key per environment).
- `Seed:AdminPassword` — the first admin's password (`Admin@12345`).

For anything beyond local development, move these out of the file into **user secrets** or environment variables:

```
dotnet user-secrets set "Jwt:SecretKey" "<a new 32+ character random string>"
dotnet user-secrets set "Seed:AdminPassword" "<a strong password>"
```

Tunable knobs live under the `Security` section (lockout thresholds, password policy, Argon2 cost, rate limits).
