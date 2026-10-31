#!/usr/bin/env python3
"""
Puts the statements that follow a CREATE TABLE in a fixed order, so that two refreshes of the same schema give the
same files.

WHY: sqlpackage writes a table's indexes (and the other statements after its CREATE TABLE) in the order of their
internal ids, and SQL Server does not hand out ids in creation order. Two databases built by the same Schema.sql
therefore list the same indexes in another order, and every refresh from another database rewrote some 30 table
files without any real change. The order has no meaning: each statement is its own batch.

What it does, for every */Tables/*.sql file under the folder given:
- the first batch (the CREATE TABLE itself) stays first;
- the batches after it (CREATE INDEX, ALTER TABLE ... ADD CONSTRAINT, extended properties, ...) are sorted by their
  text, ignoring case and white space at their edges;
- each batch keeps its own text and the white space around it, and the file keeps its line endings and BOM.
A file already in that order is not rewritten.

Usage (from the repository root, after an extract):
    python3 tools/sort-dbproject-tables.py DatabaseProject
Prints how many files it reordered.
"""
import pathlib
import re
import sys

if len(sys.argv) != 2:
    sys.exit("usage: sort-dbproject-tables.py <folder>")

root = pathlib.Path(sys.argv[1])
GO = re.compile(r"(?m)^([ \t]*GO[ \t]*\r?)$")
changed = 0

for path in sorted(root.rglob("*.sql")):
    if "Tables" not in path.relative_to(root).parts[:-1]:
        continue
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    # [batch0, GO, batch1, GO, ..., batchN, GO, tail]: a batch is the text between two GO lines.
    tokens = GO.split(text)
    if len(tokens) < 5:              # the table alone, or one statement after it: nothing to order
        continue
    batches, separators = tokens[0::2], tokens[1::2]
    head, rest, tail = batches[0], batches[1:-1], batches[-1]
    if not rest or not re.search(r"\bCREATE\s+TABLE\b", head, re.I):
        continue
    ordered = sorted(rest, key=lambda b: (b.strip().lower(), b))
    if ordered == rest:
        continue
    pieces = [head]
    for sep, batch in zip(separators, ordered + [tail]):
        pieces.append(sep)
        pieces.append(batch)
    out = "".join(pieces)
    path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + out.encode("utf-8"))
    changed += 1

print(f"sort-dbproject-tables: {changed} table file(s) put in order")
