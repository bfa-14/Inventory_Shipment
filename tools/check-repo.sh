#!/usr/bin/env bash
# Checks what git would commit (the index) for the problems that break the Windows PCs and Visual Studio:
#   1. two paths that differ only by capitals (DatabaseProject/Security and DatabaseProject/security are ONE folder on
#      Windows: one of them silently disappears there - the cause of the lost files before the DatabaseSecurity folder);
#   2. names Windows cannot create: CON, PRN, AUX, NUL, CONIN$, CONOUT$, COM1-9, LPT1-9 (also followed by spaces or by
#      any extension: "con .txt" is CON too), the characters < > : " | ? * \ and control characters, a name ending with
#      a space or a dot. Git for Windows refuses to check such a path out ("invalid path"). Each bad name is reported
#      with the folders above it, once per place;
#   3. Visual Studio and build leftovers: .vs/, bin/, obj/, *.dbmdl, *.jfm, *.suo, *.user;
#   4. DatabaseProject/DatabaseProject.sqlproj lists exactly the .sql files of the folder, with the same capitals and
#      once each (Visual Studio hides a file missing from the list, and shows a warning for a listed file that does not
#      exist). tools/sync-sqlproj.py rewrites the list; each message says what fixes that particular case.
# Changes nothing. Exit code 0 = clean, 1 = problems (listed). Run by tools/refresh-dbproject.sh and by the pre-commit
# hook in .githooks (once per clone: git config core.hooksPath .githooks).
#
# Python: the first of python3, python, "py -3" that really runs Python 3.7 or later. On Windows the python.org
# installer gives python.exe and py.exe but no python3.exe, and "python3" is often the Microsoft Store alias, which
# only prints an install message: trusting "command -v python3" would block every commit there.
# The list never turns into a Python error: a character the console cannot show is printed as \u....
set -euo pipefail

root="$(git rev-parse --show-toplevel)"      # outside a repository git says so and the script stops here
cd "$root"

py=""
for c in python3 python "py -3"; do
  # $c unquoted on purpose: "py -3" is a command and its argument.
  if $c -c 'import sys; sys.exit(sys.version_info < (3, 7))' >/dev/null 2>&1; then py="$c"; break; fi
done
if [ -z "$py" ]; then
  echo "check-repo: Python 3 not found (tried python3, python and py -3)."
  echo "            Install it (Windows: python.org, tick \"Add python.exe to PATH\"), then commit again,"
  echo "            or skip this check once, knowingly: git commit --no-verify"
  exit 1
fi

git ls-files -z --cached | $py -c '
import os, posixpath, re, subprocess, sys
from collections import Counter, defaultdict

sys.stdout.reconfigure(errors="backslashreplace")
python = sys.argv[1]
paths = [p for p in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\0") if p]
problems = []

# 1. Same path but for capitals - every folder level counts, since Windows folders are case-insensitive too.
spellings = defaultdict(set)
for p in paths:
    parts = p.split("/")
    for i in range(1, len(parts) + 1):
        prefix = "/".join(parts[:i])
        spellings[prefix.lower()].add(prefix)
for key in sorted(spellings):
    names = sorted(spellings[key])
    if len(names) > 1:
        problems.append("differ only by capitals (one is lost on Windows): " + " | ".join(names))

# 2. Names Windows cannot create. A device name stays a device name with spaces and / or an extension after it
#    (the rule of Git for Windows, is_valid_win32_path), so "con .txt" and "aux .tar.gz" are refused like "con".
reserved = re.compile(r"(con|prn|aux|nul|conin\$|conout\$|com[0-9¹²³]|lpt[0-9¹²³]) *(\..*)?", re.I | re.S)
bad_chars = re.compile(r"[<>:\"|?*\\\x00-\x1f]")
seen = set()
for p in paths:
    parts = p.split("/")
    for i, part in enumerate(parts):
        where = "/".join(parts[:i + 1])      # the place, so two folders holding the same bad name are both shown
        if where in seen:
            continue
        seen.add(where)
        why = []
        if reserved.fullmatch(part):
            why.append("a reserved Windows name")
        if bad_chars.search(part):
            why.append("a character Windows refuses")
        if part.endswith((" ", ".")):
            why.append("ends with a space or a dot")
        if why:
            problems.append("cannot be created on Windows (" + ", ".join(why) + "): " + repr(where))

# 3. Visual Studio and build leftovers.
leftover_dir = {".vs", "bin", "obj"}
leftover_ext = (".dbmdl", ".jfm", ".suo", ".user")
for p in paths:
    parts = p.split("/")
    if leftover_dir & {x.lower() for x in parts[:-1]} or parts[-1].lower().endswith(leftover_ext):
        problems.append("Visual Studio / build leftover (remove it with git rm --cached): " + p)

# 4. The .sqlproj file list matches the .sql files, capitals included, each file once.
proj = "DatabaseProject/DatabaseProject.sqlproj"
if proj in paths:
    root = "DatabaseProject/"
    sync = "run " + python + " tools/sync-sqlproj.py " + proj + ", then git add " + proj
    entities = {"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "\x27"}

    def include(value):
        # sync-sqlproj.py writes the names with quoteattr: R&D.sql is listed as R&amp;D.sql.
        def entity(m):
            name = m.group(1)
            if not name.startswith("#"):
                return entities[name]
            code = int(name[2:], 16) if name.startswith("#x") else int(name[1:])
            return chr(code) if code < 0x110000 else m.group(0)
        return re.sub(r"&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);", entity, value).replace("\\", "/")

    def in_build_dir(rel):
        return bool({"bin", "obj"} & {x.lower() for x in rel.split("/")})

    # The staged copy, not the working file: the check is about what the commit will hold.
    text = subprocess.run(["git", "show", ":" + proj], check=True, capture_output=True).stdout.decode("utf-8-sig", "replace")
    deploy = {include(m).lower() for m in re.findall(r"<(?:PreDeploy|PostDeploy)\s+Include=\"([^\"]+)\"", text)}
    builds = [include(m) for m in re.findall(r"<Build\s+Include=\"([^\"]+)\"", text)]
    listed = set(builds)
    tracked = {p.lower() for p in paths}
    files = set()
    for p in paths:
        if not p.startswith(root) or not p.lower().endswith(".sql"):
            continue
        rel = p[len(root):]
        if in_build_dir(rel):
            continue
        if rel.lower() in deploy or rel.split("/")[-1].lower().startswith("script."):
            continue
        files.add(rel)
    for rel in sorted(files - listed, key=str.lower):
        if not os.path.isfile(root + rel):
            why = "deleted on disk but still in git (git rm " + root + rel + ", or git restore it)"
        elif not rel.endswith(".sql"):
            # Visual Studio takes Legacy.SQL as a .sql file, but sync-sqlproj.py looks for "*.sql" and on Linux
            # that pattern does not match capitals: only a lower-case extension gets listed everywhere.
            why = ("not in the file list, and sync-sqlproj.py does not see an extension in capitals on Linux (git mv "
                   + root + rel + " " + root + rel[:-4] + ".sql, then " + sync + ")")
        else:
            why = "not in the file list (" + sync + ")"
        problems.append(proj + ": " + why + ": " + rel)
    for rel in sorted(listed - files, key=str.lower):
        if rel.lower() in deploy or rel.split("/")[-1].lower().startswith("script."):
            why = "a deployment script listed as Build (" + sync + ")"
        elif (os.path.isfile(root + rel) and not in_build_dir(rel)
              and posixpath.normpath(root + rel).lower() not in tracked):
            why = "listed and on disk, but not added to git (git add " + root + rel + ")"
        else:
            why = "listed but not in git with these capitals (" + sync + ")"
        problems.append(proj + ": " + why + ": " + rel)
    counts = Counter(b.lower() for b in builds)
    for key in sorted(k for k, n in counts.items() if n > 1):
        names = " | ".join(sorted({b for b in builds if b.lower() == key}))
        problems.append(proj + ": listed %d times instead of once (%s): %s" % (counts[key], sync, names))

if problems:
    print("check-repo: %d problem(s) in what git would commit:" % len(problems))
    for line in problems:
        print("  - " + line)
    sys.exit(1)
print("check-repo: OK (%d files checked)" % len(paths))
' "$py"
