#!/usr/bin/env python3
"""
Rewrites the file list of an old-format (SSDT) .sqlproj so it matches the .sql files on disk.

Old-format database projects list every file by name (<Build Include="..."/>). When the folder is refreshed from the
database (sqlpackage Extract, Schema Compare on another machine, a git pull), new files are missing from the list and
deleted ones stay in it - Visual Studio then hides the new objects and shows the old ones with a warning icon.

Usage (from the repository root):
    python3 tools/sync-sqlproj.py DatabaseProject/DatabaseProject.sqlproj

Keeps everything else in the project file (properties, PreDeploy / PostDeploy scripts, references, other None items).
Pre / post deployment scripts (Script.*.sql or files already declared as PreDeploy / PostDeploy) are never added as Build.
"""
import pathlib
import re
import sys
from xml.sax.saxutils import quoteattr

if len(sys.argv) != 2:
    sys.exit("usage: sync-sqlproj.py <path to .sqlproj>")

proj = pathlib.Path(sys.argv[1]).resolve()
root = proj.parent
raw = proj.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
text = raw.decode("utf-8-sig")
newline = "\r\n" if "\r\n" in text else "\n"

if re.search(r"<Project[^>]*\bSdk\s*=", text):
    sys.exit("This is an SDK-style project: it already picks up every .sql file by itself. Nothing to do.")

deploy = {m.replace("\\", "/").lower() for m in re.findall(r'<(?:PreDeploy|PostDeploy)\s+Include="([^"]+)"', text)}

# Remove the old Build items, the Folder items and the None items that point at .sql files.
text = re.sub(r'[ \t]*<Build\s+Include="[^"]*"\s*/>[ \t]*\r?\n?', "", text)
text = re.sub(r'[ \t]*<Build\s+Include="[^"]*"\s*>.*?</Build>[ \t]*\r?\n?', "", text, flags=re.S)
kept_folders = set()
def _folder(m):
    path = m.group(1).replace("\\", "/").rstrip("/")
    if (root / path).is_dir():
        kept_folders.add(pathlib.PurePosixPath(path))
    return ""
text = re.sub(r'[ \t]*<Folder\s+Include="([^"]*)"\s*/>[ \t]*\r?\n?', _folder, text)
text = re.sub(r'[ \t]*<None\s+Include="[^"]*\.sql"\s*/>[ \t]*\r?\n?', "", text, flags=re.I)
text = re.sub(r'[ \t]*<ItemGroup>\s*</ItemGroup>[ \t]*\r?\n?', "", text)

files = []
for p in sorted(root.rglob("*.sql"), key=lambda x: str(x).lower()):
    rel = p.relative_to(root)
    if {"bin", "obj"} & {part.lower() for part in rel.parts}:
        continue
    key = rel.as_posix().lower()
    if key in deploy or rel.name.lower().startswith("script."):
        continue
    files.append(rel)

folders = {pathlib.Path(str(f)) for f in kept_folders}     # folders already declared that still exist (e.g. Properties)
for rel in files:
    for parent in list(rel.parents)[:-1]:
        folders.add(parent)

lines = ["  <ItemGroup>"]
for f in sorted(folders, key=lambda x: str(x).lower()):
    lines.append(f"    <Folder Include={quoteattr(str(f).replace('/', chr(92)) + chr(92))} />")
for rel in files:
    lines.append(f"    <Build Include={quoteattr(str(rel).replace('/', chr(92)))} />")
lines.append("  </ItemGroup>")
block = newline.join(lines) + newline

idx = text.rfind("</Project>")
if idx < 0:
    sys.exit("No </Project> tag found - is this a .sqlproj file?")
text = text[:idx] + block + text[idx:]

proj.write_bytes((b"\xef\xbb\xbf" if bom else b"") + text.replace("\r\n", "\n").replace("\n", newline).encode("utf-8"))
print(f"{proj.name}: {len(files)} .sql files and {len(folders)} folders listed.")
