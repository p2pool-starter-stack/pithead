// Native JSON syntax validation plus a raw member walk: JSON.parse alone loses duplicates.
export function parseConfigDocument(text) {
  let cfg;
  try {
    cfg = JSON.parse(text);
  } catch {
    throw new Error("Not valid JSON.");
  }
  const tokens = text.match(/"(?:[^"\\]|\\.)*"|[{}[\]:,]|[^{}[\]:,\s]+/g);
  let cursor = 0;
  const childPath = (path, key) => {
    const escaped = JSON.stringify(key).slice(1, -1);
    return path ? `${path}.${escaped}` : escaped;
  };
  const walk = (path) => {
    const token = tokens[cursor++];
    if (token === "{") {
      const seen = new Set();
      while (tokens[cursor] !== "}") {
        const key = JSON.parse(tokens[cursor++]);
        const child = childPath(path, key);
        if (seen.has(key)) {
          throw new Error(
            `duplicate key ${JSON.stringify(key)} at ${path || "the top level"} (path ${child})`,
          );
        }
        seen.add(key);
        cursor++; // colon; native JSON.parse already checked the grammar
        walk(child);
        if (tokens[cursor] === ",") cursor++;
      }
      cursor++;
    } else if (token === "[") {
      let index = 0;
      while (tokens[cursor] !== "]") {
        walk(`${path}[${index++}]`);
        if (tokens[cursor] === ",") cursor++;
      }
      cursor++;
    }
  };
  walk("");
  return cfg;
}
