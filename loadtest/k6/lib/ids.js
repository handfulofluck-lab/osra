// Deterministic ids for synthetic families. MUST stay identical to the rule in
// services/api/scripts/loadtest-seed.ts (ltId, ltShape): the seed writes these rows, k6 addresses them.
// Pure JavaScript (no k6 imports) so loadtest/smoke/node-smoke.mjs can use it too.

const KIND = { family: "1", parent: "2", child: "3", device: "4" };
const hex12 = (n) => n.toString(16).padStart(12, "0");

export const ltId = (kind, family, sub = 0) => `0000000${KIND[kind]}-1000-4000-8000-${hex12(family * 16 + sub)}`;

/** Even families: 2 parents, children with 2 + 1 devices. Odd: 1 parent, 1 + 1. Averages 1.5 parents, 2.5 devices. */
export const ltShape = (family) => ({ parents: family % 2 === 0 ? 2 : 1, devicesPerChild: family % 2 === 0 ? [2, 1] : [1, 1] });

/** Every device of a family with the child it belongs to. */
export function ltDevices(family) {
  const out = [];
  let d = 0;
  ltShape(family).devicesPerChild.forEach((count, c) => {
    for (let k = 0; k < count; k++, d++) out.push({ deviceId: ltId("device", family, d), childId: ltId("child", family, c), familyId: ltId("family", family) });
  });
  return out;
}

/** Device number n (0-based) across all families, for arrival-rate scenarios that pick a random device. */
export function ltDeviceByIndex(families, n) {
  const fam = Math.floor(n / 2.5) % families; // close enough for random picking
  const list = ltDevices(fam);
  return list[n % list.length];
}

export function ltParent(family, p = 0) {
  const shape = ltShape(family);
  const idx = Math.min(p, shape.parents - 1);
  return { parentId: ltId("parent", family, idx), familyId: ltId("family", family), familyRole: idx === 0 ? "owner" : "co-parent", children: shape.devicesPerChild.map((_, c) => ltId("child", family, c)) };
}
