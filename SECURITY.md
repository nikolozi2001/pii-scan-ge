# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/nikolozi2001/pii-scan-ge/security/advisories/new)
rather than opening a public issue.

Expect an initial response within seven days. If a fix is needed, it will land on
`main` and the advisory will be published alongside it.

Anything that is not sensitive — a false positive, a missed pattern, a
performance problem — belongs in a normal [issue](https://github.com/nikolozi2001/pii-scan-ge/issues).

**Never include real data in a report.** Not a personal number, not a phone
number, not a row from your database. Describe the format or the column name
instead. A report containing live personal data is itself a data protection
incident, and it will be deleted rather than acted on.

## What the script does and does not do

`pii_scan.sql` runs against a database that, by definition, may contain personal
data. These properties are worth stating precisely.

**It does not write to the database being scanned.** No DDL, no DML, no changes
to any user object. It creates temporary tables in `tempdb` for its own working
state; those are session-scoped and can be dropped at the end (see section 12 of
the script).

**It makes no network calls.** No downloads, no telemetry, no external
dependencies. The file is plain T-SQL and does everything inside the SQL Server
session you run it in.

**It does not return the values it reads.** The reports contain schema, table and
column names, counts, and percentages — never a sampled value. Column data is
read into memory for pattern matching and discarded.

One qualification on that last point. Server error messages can embed the value
that caused them, so the skipped-columns report truncates any error text at the
first quotation mark and keeps the error number instead. If you find any other
path by which a real value can reach the output, that is a security issue and
the reporting process above applies.

## Scope

Out of scope: the accuracy of detection itself. A missed personal number or a
column flagged in error is a correctness bug, not a vulnerability — open a normal
issue. In scope: anything that causes the script to write to a database, transmit
data anywhere, expose sampled values, or execute unintended SQL.

## A note on running it

The script reads production data by design. Run it against a read-only replica
where you can, treat its output as sensitive (table and column names alone tell
an attacker where to look), and remember that permissions are the real control —
it can only read what the account running it can read.
