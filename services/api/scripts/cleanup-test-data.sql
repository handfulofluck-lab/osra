-- Cleanup of test leftovers created by QA runs (probe, e2e, audits, physical-device pass).
--
-- KEEPS the seeded demo family (demo@familyshield.dev / child "Alex") that testers use.
-- Removes: families owned by QA/e2e/audit test parents, and non-"Alex" children inside the demo
-- family (test children created by e2e/probe/device passes, with their devices and rows).
--
--   DRY RUN (default, prints the plan):   psql -h 127.0.0.1 -U familyshield -d familyshield -f cleanup-test-data.sql
--   APPLY (deletes, inside one tx):       psql -h 127.0.0.1 -U familyshield -d familyshield -v apply=1 -f cleanup-test-data.sql
--
-- Safe by default on purpose: it is committed to a public repo, so an accidental run must not delete.

\pset pager off

-- Which parents/families are "test" leftovers. Keep this list narrow and explicit.
\set test_parent_pattern '^(qa-|verify-|verify2-|ios1-)'
\set demo_email 'demo@familyshield.dev'

\echo '=== BEFORE ==='
SELECT (SELECT count(*) FROM "Family") families, (SELECT count(*) FROM "Parent") parents,
       (SELECT count(*) FROM "Child") children, (SELECT count(*) FROM "Device") devices,
       (SELECT count(*) FROM "LocationPing") pings, (SELECT count(*) FROM "Alert") alerts;

\echo '=== will remove these test parents (their families go with them) ==='
SELECT p.email FROM "Parent" p
WHERE p.email ~ :'test_parent_pattern' OR p.email = 'e2e-crossfamily@example.com'
ORDER BY p.email;

\echo '=== will remove these demo-family children (Alex is kept) ==='
SELECT c."displayName" FROM "Child" c
WHERE c."familyId" = (SELECT "familyId" FROM "Parent" WHERE email = :'demo_email' LIMIT 1)
  AND c."displayName" <> 'Alex'
ORDER BY c."displayName";

-- Orphan families: no parent AND no child left. These evade every other rule in this script, because
-- del_family is derived from Parent.email — a family whose parent was deleted (erasure, a partial
-- cleanup, an interrupted run) is unreachable and accumulates forever. Found on the shared DB on
-- 2026-10-17: two `QA Family B` rows with 0 parents / 0 children / 0 invites, which made "restored to
-- demo state" read true while the Family table kept growing.
\echo '=== will remove these orphan families (no parent left, no child left) ==='
SELECT f.name, f.id, f."createdAt" FROM "Family" f
WHERE NOT EXISTS (SELECT 1 FROM "Parent" p WHERE p."familyId" = f.id)
  AND NOT EXISTS (SELECT 1 FROM "Child" c WHERE c."familyId" = f.id)
  AND f.id <> (SELECT "familyId" FROM "Parent" WHERE email = :'demo_email' LIMIT 1)
ORDER BY f."createdAt";

\if :{?apply}
\else
  \set apply 0
\endif

\if :apply
\echo '=== APPLYING ==='
BEGIN;
CREATE TEMP TABLE del_child ON COMMIT DROP AS
  SELECT c.id AS id FROM "Child" c
  WHERE c."familyId" NOT IN (SELECT "familyId" FROM "Parent" WHERE email = :'demo_email')
     OR (c."familyId" = (SELECT "familyId" FROM "Parent" WHERE email = :'demo_email' LIMIT 1)
         AND c."displayName" <> 'Alex');
CREATE TEMP TABLE del_family ON COMMIT DROP AS
  SELECT DISTINCT p."familyId" AS id FROM "Parent" p
  WHERE p.email ~ :'test_parent_pattern' OR p.email = 'e2e-crossfamily@example.com';
-- Orphans are computed AFTER the child deletes below, so "no child" means "none left", not "none ever".
CREATE TEMP TABLE del_orphan_family (id text);

DELETE FROM "LocationPing"  WHERE "childId" IN (SELECT id FROM del_child);
DELETE FROM "Device"        WHERE "childId" IN (SELECT id FROM del_child);
DELETE FROM "Geofence"      WHERE "childId" IN (SELECT id FROM del_child);
DELETE FROM "RuleSet"       WHERE "childId" IN (SELECT id FROM del_child);
DELETE FROM "Alert"         WHERE "childId" IN (SELECT id FROM del_child);
DELETE FROM "SocialEvent"   WHERE "childId" IN (SELECT id FROM del_child);
DELETE FROM "ActivityEvent" WHERE "childId" IN (SELECT id FROM del_child);
DELETE FROM "ConsentRecord" WHERE "childId" IN (SELECT id FROM del_child);
DELETE FROM "Child"         WHERE id IN (SELECT id FROM del_child);
DELETE FROM "FamilyInvite"  WHERE "familyId" IN (SELECT id FROM del_family);
DELETE FROM "Parent"        WHERE "familyId" IN (SELECT id FROM del_family);
DELETE FROM "Family"        WHERE id IN (SELECT id FROM del_family);
INSERT INTO del_orphan_family (id)
  SELECT f.id FROM "Family" f
  WHERE NOT EXISTS (SELECT 1 FROM "Parent" p WHERE p."familyId" = f.id)
    AND NOT EXISTS (SELECT 1 FROM "Child" c WHERE c."familyId" = f.id)
    AND f.id <> (SELECT "familyId" FROM "Parent" WHERE email = :'demo_email' LIMIT 1);
DELETE FROM "FamilyInvite" WHERE "familyId" IN (SELECT id FROM del_orphan_family);
DELETE FROM "Family"       WHERE id IN (SELECT id FROM del_orphan_family);
COMMIT;
\echo '=== APPLIED ==='
\else
\echo '=== DRY RUN — nothing deleted. Re-run with -v apply=1 to execute. ==='
\endif

\echo '=== AFTER ==='
SELECT (SELECT count(*) FROM "Family") families, (SELECT count(*) FROM "Parent") parents,
       (SELECT count(*) FROM "Child") children, (SELECT count(*) FROM "Device") devices,
       (SELECT count(*) FROM "LocationPing") pings, (SELECT count(*) FROM "Alert") alerts;

-- Explicit assertion, because the counts above can look right while the Family table grows: the TR-08
-- run reported 3 families / 1 child and read as "fine". One family is the seeded demo family; anything
-- else is residue this script failed to reach, and it must be investigated, not ignored.
\echo '=== assertion: exactly one family (the seeded demo family) ==='
SELECT CASE WHEN count(*) = 1
            THEN 'OK: 1 family — demo family only'
            ELSE 'FAIL: ' || count(*) || ' families remain — run the orphan query above and investigate'
       END AS families_assertion
FROM "Family";

\echo '=== demo family must still be intact ==='
SELECT f.name AS family, c."displayName" AS child
FROM "Family" f JOIN "Child" c ON c."familyId" = f.id
WHERE f.id = (SELECT "familyId" FROM "Parent" WHERE email = :'demo_email' LIMIT 1)
ORDER BY c."displayName";
