import assert from 'node:assert/strict';


export function makeEnv({ href = 'http://pithead.test/', stored = {}, responses = [], session = {} } = {}) {
    const fetches = [];
    const paints = [];
    const urls = [];
    const doc = {
        title: '',
        documentElement: {
            attrs: {},
            setAttribute(name, value) { this.attrs[name] = value; },
        },
        getElementById: () => null,
    };
    const reloads = [];
    const windowHandlers = [];
    let interval = null;
    const env = {
        doc,
        href,
        storage: {
            getItem: (k) => (k in stored ? stored[k] : null),
            setItem: (k, v) => { stored[k] = String(v); },
        },
        fetchFn: (url, opts) => {
            fetches.push({ url, opts });
            assert.ok(responses.length > 0, `unexpected fetch: ${url}`);
            return responses.shift()(url, opts);
        },
        replaceUrl: (u) => urls.push(u),
        schedule: (fn, ms) => { interval = { fn, ms }; },
        renderApp: (props) => paints.push(props),
        reload: () => reloads.push(1),
        store: {
            getItem: (k) => (k in session ? session[k] : null),
            setItem: (k, v) => { session[k] = String(v); },
        },
        onWindowEvent: (fn) => windowHandlers.push(fn),
    };
    return {
        env, fetches, paints, urls, doc, stored, session, reloads, windowHandlers,
        interval: () => interval,
        last: () => paints[paints.length - 1],
    };
}

export const ok = (body) => () => Promise.resolve({ ok: true, json: async () => body });
export const httpError = (status) => () => Promise.resolve({ ok: false, status });
export const aborted = () => () => Promise.reject(new DOMException('signal timed out', 'TimeoutError'));
