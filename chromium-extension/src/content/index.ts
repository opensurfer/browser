declare const openbrowser: any;
declare module "react-markdown";
declare module "remark-gfm";
declare module "remark-math";
declare module "rehype-katex";

// ── OpenSurfer capture (MAIN world) ──────────────────────────────────────────
// Runs in the page's real JS context (world: MAIN) so fetch/XHR overrides
// actually intercept the page's own network calls.
// Dispatches CustomEvent → bridge.ts (isolated world) → background → server.

(() => {
  if ((window as any).__opensurfer_ext) return;
  (window as any).__opensurfer_ext = true;

  const started = Date.now();
  const events: any[] = [];
  const clip = (s: any) =>
    typeof s === "string" && s.length > 4000 ? s.slice(0, 4000) + "…" : s;

  const flush = () => {
    if (events.length === 0) return;
    const snapshot = events.splice(0);
    window.dispatchEvent(
      new CustomEvent("__opensurfer_trace", {
        detail: {
          name: location.hostname.replace(/^www\./, ""),
          trace: {
            startedAt: new Date(started).toISOString(),
            url: location.href,
            events: snapshot
          }
        }
      })
    );
  };

  const push = (e: any) => {
    e.t = Date.now() - started;
    events.push(e);
    if (events.length >= 20) flush();
  };

  // Extract a plain-object headers map from an init.headers / Request.headers value.
  const readHeaders = (h: any): Record<string, string> => {
    const out: Record<string, string> = {};
    if (!h) return out;
    try {
      if (typeof h.forEach === "function") {
        h.forEach((v: string, k: string) => (out[k.toLowerCase()] = v));
      } else if (Array.isArray(h)) {
        for (const [k, v] of h) out[String(k).toLowerCase()] = String(v);
      } else if (typeof h === "object") {
        for (const k of Object.keys(h)) out[k.toLowerCase()] = String(h[k]);
      }
    } catch {}
    return out;
  };

  // Emit an observation of a real page request so the extension can learn how
  // the app talks to its own API endpoints.
  const emitObservation = (
    method: string,
    url: string,
    headers: Record<string, string>,
    bodyStr: string | undefined
  ) => {
    try {
      const u = new URL(url, location.href);
      // Only worth observing cross-origin API-style calls
      if (u.protocol !== "https:" && u.protocol !== "http:") return;
      window.dispatchEvent(
        new CustomEvent("__opensurfer_observed", {
          detail: {
            host: u.host,
            pageOrigin: location.origin,
            method: method.toUpperCase(),
            url: u.href,
            headers,
            bodyLen: bodyStr ? bodyStr.length : 0,
            hasJsonBody: !!bodyStr && /^\s*[{[]/.test(bodyStr),
            observedAt: Date.now()
          }
        })
      );
    } catch {}
  };

  const _f = window.fetch;
  window.fetch = async function (input: any, init?: any) {
    const url = typeof input === "string" ? input : input?.url;
    const method = ((init?.method || input?.method) ?? "GET").toUpperCase();
    let rb = init?.body;
    try {
      rb = typeof rb === "string" ? rb : undefined;
    } catch {}
    // Observe the outgoing request headers before we make the call.
    const initHeaders = readHeaders(init?.headers);
    const reqHeaders =
      input && typeof input !== "string"
        ? { ...readHeaders(input.headers), ...initHeaders }
        : initHeaders;
    emitObservation(
      method,
      url,
      reqHeaders,
      typeof rb === "string" ? rb : undefined
    );
    const res = await _f.apply(this, arguments as any);
    let respBody: string | undefined;
    try {
      respBody = clip(await res.clone().text());
    } catch {}
    push({
      kind: "net",
      method,
      url,
      reqBody: clip(rb),
      status: res.status,
      respType: res.headers.get("content-type") ?? "",
      respBody
    });
    return res;
  };

  const _open = XMLHttpRequest.prototype.open;
  const _send = XMLHttpRequest.prototype.send;
  const _setHeader = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function (m: string, u: string) {
    (this as any).__osc = {
      method: (m ?? "GET").toUpperCase(),
      url: u,
      headers: {} as Record<string, string>
    };
    return _open.apply(this, arguments as any);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (
    name: string,
    value: string
  ) {
    const c = (this as any).__osc;
    if (c && c.headers) c.headers[String(name).toLowerCase()] = String(value);
    return _setHeader.apply(this, arguments as any);
  };
  XMLHttpRequest.prototype.send = function (b?: any) {
    const c = (this as any).__osc ?? {};
    emitObservation(
      c.method || "GET",
      c.url || "",
      c.headers || {},
      typeof b === "string" ? b : undefined
    );
    this.addEventListener("load", () => {
      let r: string | undefined;
      try {
        r = clip(this.responseText);
      } catch {}
      push({
        kind: "net",
        method: c.method,
        url: c.url,
        reqBody: typeof b === "string" ? clip(b) : undefined,
        status: this.status,
        respType: this.getResponseHeader("content-type") ?? "",
        respBody: r
      });
    });
    return _send.apply(this, arguments as any);
  };

  const nav = (u: string) => {
    push({ kind: "nav", url: u });
    flush();
  };
  const _ps = history.pushState;
  history.pushState = function (...args: any[]) {
    nav(args[2]);
    return _ps.apply(this, args);
  };
  window.addEventListener("popstate", () => nav(location.href));
  nav(location.href);

  window.addEventListener("pagehide", flush);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flush();
  });
})();
