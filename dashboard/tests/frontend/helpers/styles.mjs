// Read a stylesheet and its local imports in cascade order for source-level CSS checks.
import { readFileSync } from "node:fs";

export function readStylesheet(url) {
  return readFileSync(url, "utf8").replace(
    /^@import "([^"]+)";\n/gm,
    (_, relative) => readStylesheet(new URL(relative, url)),
  );
}
