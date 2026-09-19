// The wizard's shell and chrome (#1868), asserted the way workerview.test.mjs asserts dashboard.css:
// parse the files and read what they declare. These are static assertions — no layout engine runs
// here, so nothing below proves a rendered button measured 32 px. What they DO hold is the property
// that broke: a control that carries no class at all falls through to the user-agent style, and a
// mount that is never cleared keeps whatever the server shipped inside it.
//
// A new file rather than wizard.test.mjs, which is at 765 against a 765 ceiling.

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import test from "node:test";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const WIZARD_MJS = read("../../../mining_dashboard/web/static/wizard/wizard.mjs");
const WIZARD_CSS = read("../../../mining_dashboard/web/static/wizard/wizard.css");
const WIZARD_HTML = read("../../../mining_dashboard/web/templates/wizard.html");
const LAYOUT_CSS = read("../../../mining_dashboard/web/static/styles/layout.css");

function ruleFor(css, selectorRe) {
  const m = css.match(new RegExp(`(^|\\})\\s*(${selectorRe.source})\\s*\\{([^}]*)\\}`, "m"));
  return m ? { selector: m[2].trim(), body: m[3] } : null;
}

// The wizard's view modules, found by the import they share rather than by a hand-kept list — a new
// view that renders a button is then covered the day it is written. The first sweep here read only
// wizard.mjs and was blind to savedrole.mjs's "Keep it", which is exactly this defect in a file the
// needle never looked at.
const STATIC = new URL("../../../mining_dashboard/web/static/", import.meta.url);
const WIZARD = new URL("../../../mining_dashboard/web/static/wizard/", import.meta.url);
const VIEWS = readdirSync(STATIC, { recursive: true })
  .filter((f) => f.endsWith(".mjs"))
  .map((f) => [f, readFileSync(new URL(f, STATIC), "utf8")])
  .filter(([f, src]) => f === "wizard/wizard.mjs" || src.includes("./wizardparts.mjs"));

test("every wizard view: a button declares a class, so none falls through to the browser default", () => {
  // An enumeration that quietly found nothing would pass this test while proving nothing, so the
  // root is asserted before the property is.
  assert.ok(VIEWS.length >= 2, `expected the wizard's view modules, found ${VIEWS.length}`);
  assert.ok(
    VIEWS.some(([f]) => f === "wizard/savedrole.mjs"),
    "savedrole.mjs no longer matches the wizard-view marker — widen the root, do not narrow the claim",
  );
  const bare = [];
  for (const [file, src] of VIEWS) {
    // Each opening tag, taken as the text after `<button` up to a comfortable bound: the tag can
    // hold arrow functions, so scanning for the closing `>` would stop at the first `=>`.
    for (const tag of src.split("<button").slice(1).map((s) => s.slice(0, 200))) {
      if (!/class="(btn-toggle[^"]*|wizard-link)"/.test(tag)) {
        bare.push(`${file}: <button${tag.split("\n")[0].trim()}`);
      }
    }
  }
  assert.deepEqual(
    bare,
    [],
    "a button with no class renders as the user-agent control (#1868): give it the dashboard's " +
      "btn-toggle skin, or wizard-link if it is deliberately a text link",
  );
});

test("wizard.css: a standalone button gets the border and radius .btn-toggle takes from its parent", () => {
  const rule = ruleFor(WIZARD_CSS, /\.wizard-shell\s+button:not\(\.wizard-link\)/);
  assert.ok(rule, "expected a `.wizard-shell button:not(.wizard-link)` rule in wizard.css");
  assert.match(rule.body, /border:\s*1px solid var\(--border\)/);
  assert.match(rule.body, /border-radius:/);
});

test("wizard.css: the button's target size clears WCAG 2.2 SC 2.5.8 (24px) as a declared floor", () => {
  const rule = ruleFor(WIZARD_CSS, /\.wizard-shell\s+button:not\(\.wizard-link\)/);
  const mh = rule.body.match(/min-height:\s*(\d+)px/);
  assert.ok(mh, "expected an explicit min-height rather than one implied by padding + line-height");
  assert.ok(
    Number(mh[1]) >= 24,
    `min-height ${mh[1]}px is below the 24px target-size floor (SC 2.5.8)`,
  );
  const link = ruleFor(WIZARD_CSS, /\.wizard-link/);
  const linkHeight = link.body.match(/min-height:\s*(\d+)px/);
  assert.ok(linkHeight, "expected the link-styled button to declare its own target-size floor");
  assert.ok(Number(linkHeight[1]) >= 24, `wizard-link min-height ${linkHeight[1]}px is below the 24px target-size floor`);
});

test("wizard shell: the server-side heading remains, without a Loading placeholder or duplicate app heading", () => {
  const shellH1s = WIZARD_HTML.match(/<h1(?=[\s>])/g) || [];
  const appH1s = WIZARD_MJS.match(/<h1(?=[\s>])/g) || [];
  assert.match(WIZARD_HTML, /<main[^>]*id="app"[^>]*>\s*<h1>/, "the shell still identifies the page");
  assert.equal(shellH1s.length, 1, "the shell must carry exactly one page heading");
  assert.doesNotMatch(WIZARD_HTML, /Loading…/, "the placeholder survives Preact renders");
  assert.equal(appH1s.length, 0, "the app must not duplicate the shell heading");
});

test("wizard section headings are h2s with the h3 appearance and a fixed top margin", () => {
  const headings = readdirSync(WIZARD)
    .filter((file) => file.endsWith(".mjs"))
    .flatMap((file) => readFileSync(new URL(file, WIZARD), "utf8").match(/<h[23](?=[\s>])/g) || []);
  assert.equal(headings.filter((tag) => tag === "<h3").length, 0, "wizard section headings must not skip h2");
  assert.equal(headings.filter((tag) => tag === "<h2").length, 16, "expected every wizard section heading");
  assert.equal((WIZARD_HTML.match(/<h1(?=[\s>])/g) || []).length + headings.length, 17, "expected one page heading and all 16 section headings");
  assert.match(LAYOUT_CSS, /h3,\s*\.wizard-shell h2\s*\{/, "wizard h2s keep the section-heading appearance");
  const h2 = ruleFor(WIZARD_CSS, /\.wizard-shell\s+h2/);
  assert.ok(h2, "expected a `.wizard-shell h2` rule");
  assert.match(h2.body, /margin-top:\s*[1-9]/, "a heading with no top margin reads as the label of the field above it");
  assert.match(h2.body, /font-weight:\s*700/, "the scoped h2 retains the h3's bold weight");
  const first = ruleFor(WIZARD_CSS, /\.wizard-shell\s+h2:first-child/);
  assert.ok(first, "expected the :first-child reset");
  assert.match(first.body, /margin-top:\s*0/);
});
