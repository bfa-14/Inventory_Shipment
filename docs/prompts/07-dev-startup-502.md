# Login shows 502 Bad Gateway — API not reachable from the Vite proxy

Cause: `vite.config.ts` proxies `/api` and `/health` to `https://localhost:7089` (`.env.development`,
`VITE_API_PROXY_TARGET`). A 502 from the proxy means nothing answered there: the API was not started, was
started with another profile/port, or exited during start-up (it applies `Repository\Database\Schema.sql` and
stops if that fails). The prompt below diagnoses it and makes `npm run dev` start the API automatically.

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (React 19 + Vite 8 + TypeScript, Windows). You may also
read and modify D:\VSProjects\Inventory_Shipment (the .NET 10 API solution) to fix anything that prevents the
API from starting. Do not change any business code or database data.

PROBLEM: the login page shows "The server ran into a problem. Please try again." and the browser console shows
POST /api/auth/login -> 502 (Bad Gateway). The Vite dev server (vite.config.ts) proxies /api and /health to
https://localhost:7089 (VITE_API_PROXY_TARGET in .env.development). 502 from the proxy = nothing is listening on
https://localhost:7089: the API (Inventory_Shipment.API, https launch profile in Properties\launchSettings.json =
https://localhost:7089;http://localhost:5121) is not running, was started with another profile, or exited at
start-up (Program.cs runs IDatabaseInitializer + permission sync + seeding before listening and the process
stops on any exception).

TASK

1. Diagnose now (PowerShell) and report:
   Get-NetTCPConnection -LocalPort 7089,5121,5173 -State Listen -ErrorAction SilentlyContinue |
     Select-Object LocalAddress, LocalPort, OwningProcess, @{n='Process';e={(Get-Process -Id $_.OwningProcess).ProcessName}}
   Then start the API in a terminal and read the whole output:
     dotnet run --project D:\VSProjects\Inventory_Shipment\Inventory_Shipment.API --launch-profile https
   Expected lines: "Database schema verified (... batches)" and "Now listening on: https://localhost:7089".
   If it exits or logs an exception (SQL Server not running, database initializer / schema batch error, port
   already in use, certificate problem), fix the root cause in the API project (schema batches must stay
   idempotent, no data loss) and start again until it is healthy. Then check from another terminal:
     curl.exe -k -s -o NUL -w "%{http_code}" https://localhost:7089/health          (expect 200)
     curl.exe -k -s -X POST https://localhost:7089/api/auth/login -H "Content-Type: application/json" -d "{\"username\":\"admin\",\"password\":\"Admin@12345\"}"
                                                                                    (expect 200 with tokens)
   If the HTTPS dev certificate is not trusted run: dotnet dev-certs https --trust (the proxy uses secure:false,
   so this only matters for opening https://localhost:7089/scalar directly).

2. Make it impossible to hit again: "npm run dev" starts the API when needed.
   a. Add scripts/dev.mjs (plain Node, no new dependencies):
      - reads VITE_API_PROXY_TARGET from .env.development (default https://localhost:7089) and API_PROJECT_DIR
        (default: ..\Inventory_Shipment\Inventory_Shipment.API resolved from the Web folder; overridable by env);
      - probes <target>/health with a 1.5 s timeout, ignoring TLS errors (NODE_TLS_REJECT_UNAUTHORIZED only for
        that probe, or an https.Agent with rejectUnauthorized:false);
      - if it answers: print "[dev] API already running on <target> (e.g. from Visual Studio) - starting web only"
        and run vite;
      - otherwise: spawn "dotnet run --project <API_PROJECT_DIR> --launch-profile https" with stdio piped and
        every line prefixed "[api] "; poll /health every second for up to 90 s printing progress; when healthy,
        start vite (lines prefixed "[web] "). If the dotnet process exits before it is healthy, print its exit
        code and "read the [api] lines above", and exit with code 1 without starting vite;
      - Ctrl+C / SIGINT / SIGTERM stops both; on Windows kill the dotnet tree with taskkill /PID <pid> /T /F.
   b. package.json scripts: "dev": "node scripts/dev.mjs", "dev:web": "vite", "dev:api": "dotnet run --project
      ../Inventory_Shipment/Inventory_Shipment.API --launch-profile https". Keep .vscode/tasks.json "dev server"
      working: its background matcher waits for "VITE v" then "Local:" - make sure vite's lines still contain
      them after the "[web] " prefix (or update the patterns).
   c. vite.config.ts: in the proxy entries add configure: (proxy) => proxy.on('error', ...) that logs one red line
      "[proxy] API not reachable at <target> - start Inventory_Shipment.API (npm run dev starts it)" and, when the
      response is still writable, answers 503 with Content-Type application/problem+json and body
      { "type": "about:blank", "title": "API not reachable", "status": 503, "code": "API_UNREACHABLE",
        "detail": "Nothing is listening on <target>. Start Inventory_Shipment.API (npm run dev starts it
        automatically, or press F5 in Visual Studio) and try again." }.
   d. src/api/http.ts: defaultMessage for 502 / 503 / 504 without a problem detail = "The API is not reachable.
      Make sure Inventory_Shipment.API is running (https://localhost:7089)." so the login page shows the real
      cause. Keep every other message unchanged.
   e. README.md of the Web project: a "Running in development" section - npm run dev (API + web), npm run dev:web
      (API already running from Visual Studio), ports 7089 / 5121 / 5173, how to change the API port in
      .env.development, sign-in admin / Admin@12345.

3. Verify and report each result:
   - with nothing running: npm run dev -> both start, http://localhost:5173/login signs in with admin /
     Admin@12345 and lands on the dashboard;
   - Ctrl+C -> nothing left listening on 7089 or 5173 (Get-NetTCPConnection);
   - API started first from Visual Studio (or dev:api), then npm run dev -> starts only vite, login works;
   - API stopped while vite runs, sign in -> the page shows the "API not reachable" message (503), no 502;
   - npm run typecheck, npm run lint, npm run build clean.
Report: what was listening at the start, the API start-up output (or the error you fixed and how), the files
added/changed, and every verification result.
```
