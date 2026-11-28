import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clone, renderApp } from '../harness.mjs';
import { POS } from '../../../mining_dashboard/web/static/network/topology.mjs';

const audit = (over) => ({
    loaded: true, would_drop: 0, counters: [], host_violations: 0, unmonitored: false, ...over,
});
const view = (egress_audit) => {
    const s = clone();
    s.egress_audit = egress_audit;
    return renderApp({ state: s });
};

test('violations present: the warning names the count and the scope pill says audited', () => {
    const out = view(audit({ would_drop: 3, host_violations: 3 }));
    assert.match(out, /id="host-audit-violations"/);
    assert.match(out, /host_violations: 3/);
    assert.match(out, /3 host packets hit the egress audit gate/);
    assert.match(out, /host traffic audited/);
    assert.doesNotMatch(out, /host-audit-unmonitored|host-audit-clean/);
});

test('a single violation is singular', () => {
    assert.match(view(audit({ would_drop: 1, host_violations: 1 })), /1 host packet hit/);
});

test('audit loaded and clean: no warning, a clean line', () => {
    const out = view(audit());
    assert.match(out, /id="host-audit-clean"/);
    assert.doesNotMatch(out, /host-audit-violations|host-audit-unmonitored/);
});

test('audit table not loaded: the unmonitored indicator shows and the scope says not observed', () => {
    const out = view(audit({ loaded: false, unmonitored: true }));
    assert.match(out, /id="host-audit-unmonitored"/);
    assert.match(out, /host traffic not observed/);
    assert.doesNotMatch(out, /host-audit-violations|host-audit-clean/);
});

test('host nodes render with the distinct host style and carry positions', () => {
    const out = view(audit());
    assert.equal((out.match(/topo-node topo-sys/g) || []).length, 3);
    const s = clone();
    const hostNodes = s.topology.nodes.filter((n) => n.scope === 'host');
    assert.deepEqual(hostNodes.map((n) => n.id).sort(), ['host-containers', 'host-time-sync', 'host-updates']);
    for (const n of hostNodes) {
        assert.equal(n.zone, 'host');
        assert.ok(POS[n.id], `${n.id} needs a POS entry`);
    }
});

test('every fixture topology edge endpoint can be placed', () => {
    const s = clone();
    const ids = new Set(Object.keys(POS));
    for (const e of s.topology.edges) {
        assert.ok(ids.has(e.from) && ids.has(e.to), `${e.from}->${e.to}`);
    }
});
