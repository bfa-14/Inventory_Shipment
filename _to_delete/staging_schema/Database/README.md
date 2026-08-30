# Database scripts

The application creates the database, applies the schema, and seeds the first admin automatically
on start-up, so these scripts are **optional**. Use them if you would rather set things up by hand in SSMS.

Run in order against your server (the scripts target a database named `Inventory_Shipment`):

1. **`01_Create_Schema.sql`** — creates the `Inventory_Shipment` database (if missing) and the tables
   `Users`, `RefreshTokens`, `LoginAudit`. Safe to run repeatedly.
2. **`02_Seed_Admin.sql`** — inserts the first administrator:

   | Username | Password |
   |----------|--------------|
   | `admin`  | `Admin@12345` |

   The stored value is an **Argon2id** hash — the exact format the API produces and checks. Change the
   password from the app after the first sign-in.

If you run `02_Seed_Admin.sql` yourself, set `"Seed": { "Enabled": false }` in `appsettings.json`
(or just leave `Seed:AdminPassword` empty) so the app doesn't also try to seed.

> To seed a *different* password, don't hand-edit the hash — the app can't verify one made by hand.
> Instead leave the seeding to the app: set `Seed:AdminPassword` to the password you want and start the
> app against an empty `Users` table, or create additional users through `POST /api/users` once signed in.
