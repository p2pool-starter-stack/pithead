import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

import {
  contrastRatio,
  DARK_BLOCK,
  DASHBOARD_CSS,
  LIGHT_BLOCK,
  themeToken,
} from "../helpers/contrast.mjs";

const STATIC_DIR = new URL("../../../mining_dashboard/web/static/", import.meta.url);

// The declarations that clear the UA <button> chrome; a link-button missing any of them paints as
// a box rather than as text.
const RESET = [
  [/background:\s*none/, "the UA ButtonFace fill"],
  [/border:\s*none/, "the UA outset border"],
  [/padding:\s*0/, "the UA button padding"],
  [/font:\s*inherit/, "the UA button font"],
];

test(".btn-link matches with NO ancestor, so every caller gets the chrome reset (#1861)", () => {
  // The bug this pins: a descendant selector (`.advanced-hint .btn-link`) silently excludes any
  // caller outside that one container. Asserted on the selector itself, since a DOM-free test
  // cannot walk ancestors — a bare single-class selector matches wherever the class is used.
  const rule = DASHBOARD_CSS.match(/^\.btn-link \{([^}]*)\}/m);
  assert.ok(rule, "expected a bare `.btn-link` rule — a scoped one misses callers in other cards");
  for (const [re, what] of RESET) {
    assert.match(rule[1], re, `.btn-link must clear ${what}, or it ships as a UA-chrome box`);
  }
  assert.match(rule[1], /color:\s*var\(--accent\)/, ".btn-link must take the theme's accent colour");
});

test("every .btn-link caller is reached by that rule, whatever card it lives in (#1861)", () => {
  // The selector is only as good as the callers it covers: scan the sources for the class and
  // prove the rule that matches them is the unscoped one, not a container-scoped variant.
  const files = readdirSync(STATIC_DIR, { recursive: true }).filter(
    (f) => f.endsWith(".mjs") && !f.startsWith("vendor/"),
  );
  const callers = files.filter((f) =>
    readFileSync(new URL(f, STATIC_DIR), "utf8").includes('class="btn-link"'),
  );
  // Both of today's callers, in two different containers — the Advanced hint and the Earnings
  // card. The second is the one a scoped selector missed.
  assert.ok(callers.length >= 2, `expected .btn-link in 2+ sources, found ${callers.length}`);
  assert.ok(callers.includes("app/earnings.mjs"), "the Earnings hint must be a .btn-link caller");
  const scoped = DASHBOARD_CSS.match(/^\.\S+ \.btn-link \{/m);
  assert.equal(scoped, null, `a container-scoped .btn-link rule would miss callers: ${scoped?.[0]}`);
});

test(".btn-link text clears AA on the card it sits on, in both themes (#1861, #1858)", () => {
  // The hint lives inside a `.card`, so the backdrop is --card. The foreground is read out of the
  // rule that actually reaches an unscoped `.btn-link` — not assumed — so a re-scoped selector
  // fails here too instead of leaving this assertion measuring a colour nothing applies.
  const rule = DASHBOARD_CSS.match(/^\.btn-link \{([^}]*)\}/m);
  assert.ok(rule, "no unscoped `.btn-link` rule reaches the button, so it keeps the UA fill");
  const token = rule[1].match(/color:\s*var\((--[\w-]+)\)/);
  assert.ok(token, "expected .btn-link to take its colour from a theme token");
  for (const [theme, block] of [["dark", DARK_BLOCK], ["light", LIGHT_BLOCK]]) {
    const fg = themeToken(DASHBOARD_CSS, block, token[1]);
    const card = themeToken(DASHBOARD_CSS, block, "--card");
    const ratio = contrastRatio(fg, card);
    assert.ok(ratio >= 4.5, `${theme} .btn-link contrast ${ratio.toFixed(2)}:1 is below AA (4.5:1)`);
  }
  // The chrome this replaced really was the failure, so the numbers above are not a vacuous pass:
  // --accent on Chromium's ButtonFace (#efefef) is 2.20:1 in dark, --text-muted on it 2.67:1.
  const darkAccent = themeToken(DASHBOARD_CSS, DARK_BLOCK, "--accent");
  assert.ok(contrastRatio(darkAccent, "#efefef") < 4.5, "the UA ButtonFace pair must fail AA");
});

test(".eva-hint resolves to wrapping at spaces only, after .eva-table td (#1861)", () => {
  // `.eva-table td` sets overflow-wrap:anywhere for #83's long values; the hint cell must land
  // back on `normal`. Both are compound selectors of equal weight in the class column, so the
  // override needs BOTH higher specificity (td.eva-hint adds an element) and later source order.
  const generic = DASHBOARD_CSS.search(/^\.eva-table td \{/m);
  const hint = DASHBOARD_CSS.search(/^\.eva-table td\.eva-hint \{/m);
  assert.ok(generic >= 0, "expected the `.eva-table td` rule the hint has to override");
  assert.ok(hint > generic, "`.eva-table td.eva-hint` must be declared after `.eva-table td`");
  const rule = DASHBOARD_CSS.match(/^\.eva-table td\.eva-hint \{([^}]*)\}/m);
  assert.match(rule[1], /overflow-wrap:\s*normal/, "the hint cell must wrap at spaces only");
  // The cell only gets that class where the hint text is, so the rule cannot reach a value cell.
  const card = readFileSync(new URL("app/earnings.mjs", STATIC_DIR), "utf8");
  assert.match(card, /r\.dim \? "text-muted eva-hint"/, "eva-hint rides the dim (hint) cell only");
});
