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
COMMIT;
\echo '=== APPLIED ==='
\else
\echo '=== DRY RUN — nothing deleted. Re-run with -v apply=1 to execute. ==='
\endif

\echo '=== AFTER ==='
SELECT (SELECT count(*) FROM "Family") families, (SELECT count(*) FROM "Parent") parents,
       (SELECT count(*) FROM "Child") children, (SELECT count(*) FROM "Device") devices,
       (SELECT count(*) FROM "LocationPing") pings, (SELECT count(*) FROM "Alert") alerts;

\echo '=== demo family must still be intact ==='
SELECT f.name AS family, c."displayName" AS child
FROM "Family" f JOIN "Child" c ON c."familyId" = f.id
WHERE f.id = (SELECT "familyId" FROM "Parent" WHERE email = :'demo_email' LIMIT 1)
ORDER BY c."displayName";
