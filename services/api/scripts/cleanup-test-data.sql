-- Cleanup of test leftovers created by QA runs (probe, e2e, audits, physical-device pass).
--
-- KEEPS the seeded demo family (demo@osratech.com / child "Alex") and every legitimate non-test
-- family, including reviewer families. Removes ONLY: families owned by explicit test-parent emails,
-- non-"Alex" children inside the demo family, and empty families with the QA Family name prefix.
-- It never deletes a family merely because it is outside the demo family.
--
--   DRY RUN (default, prints the plan):   psql -h 127.0.0.1 -U familyshield -d familyshield -f cleanup-test-data.sql
--   APPLY (deletes, inside one tx):       psql -h 127.0.0.1 -U familyshield -d familyshield -v apply=1 -f cleanup-test-data.sql
--
-- Safe by default on purpose: it is committed to a public repo, so an accidental run must not delete.

\pset pager off

-- Which parents/families are "test" leftovers. Keep this list narrow and explicit.
\set test_parent_pattern '^(qa-|verify-|verify2-|ios1-)'
\set test_orphan_pattern '^QA Family '
\set demo_email 'demo@osratech.com'

-- An absent demo anchor must stop APPLY. In particular, an empty subquery under NOT IN would
-- otherwise select every child. Run the current seed first to migrate an old-seed demo parent.
SELECT count(*) = 1 AS demo_found FROM "Parent" WHERE email = :'demo_email' \gset
\if :demo_found
\else
  \echo 'ERROR: expected exactly one current demo parent; run the current seed first. Nothing was deleted.'
  \q
\endif

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

-- Only explicitly QA-named orphan families are removable. Other empty families are preserved for
-- investigation because their former owner cannot be identified after the parent row is gone.
\echo '=== will remove these scoped QA orphan families (no parent left, no child left) ==='
SELECT f.name, f.id, f."createdAt" FROM "Family" f
WHERE NOT EXISTS (SELECT 1 FROM "Parent" p WHERE p."familyId" = f.id)
  AND NOT EXISTS (SELECT 1 FROM "Child" c WHERE c."familyId" = f.id)
  AND f.name ~ :'test_orphan_pattern'
ORDER BY f."createdAt";

\if :{?apply}
\else
  \set apply 0
\endif

\if :apply
\echo '=== APPLYING ==='
BEGIN;
CREATE TEMP TABLE del_family ON COMMIT DROP AS
  SELECT DISTINCT p."familyId" AS id FROM "Parent" p
  WHERE p.email ~ :'test_parent_pattern' OR p.email = 'e2e-crossfamily@example.com';
CREATE TEMP TABLE del_child ON COMMIT DROP AS
  SELECT c.id AS id FROM "Child" c
  WHERE c."familyId" IN (SELECT id FROM del_family)
     OR (c."familyId" = (SELECT "familyId" FROM "Parent" WHERE email = :'demo_email' LIMIT 1)
         AND c."displayName" <> 'Alex');
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
    AND f.name ~ :'test_orphan_pattern';
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

-- Explicit assertions: scoped test residue must be gone; legitimate non-demo families are not residue.
\echo '=== assertion: no explicit test-owner families remain ==='
SELECT CASE WHEN count(*) = 0
            THEN 'OK: no explicit test-owner families remain'
            ELSE 'FAIL: ' || count(*) || ' explicit test-owner parents remain'
       END AS test_families_assertion
FROM "Parent" p
WHERE p.email ~ :'test_parent_pattern' OR p.email = 'e2e-crossfamily@example.com';

\echo '=== assertion: no scoped QA orphan families remain ==='
SELECT CASE WHEN count(*) = 0
            THEN 'OK: no scoped QA orphan families remain'
            ELSE 'FAIL: ' || count(*) || ' scoped QA orphan families remain'
       END AS orphan_assertion
FROM "Family" f
WHERE f.name ~ :'test_orphan_pattern'
  AND NOT EXISTS (SELECT 1 FROM "Parent" p WHERE p."familyId" = f.id)
  AND NOT EXISTS (SELECT 1 FROM "Child" c WHERE c."familyId" = f.id);

\echo '=== demo family must still be intact ==='
SELECT f.name AS family, c."displayName" AS child
FROM "Family" f JOIN "Child" c ON c."familyId" = f.id
WHERE f.id = (SELECT "familyId" FROM "Parent" WHERE email = :'demo_email' LIMIT 1)
ORDER BY c."displayName";
