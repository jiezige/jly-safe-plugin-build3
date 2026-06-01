const DEFAULT_UPSTREAM = "https://pee.jlyapp.cn";
const DEFAULT_JLY_TOKEN = "EUDV6gd9cvJOWCBtKIfniR1zueqAjp5rSYxFso8yGX43mbZa";
const PROXY_PATHS = [
  "/app-update.json",
  "/vip1",
  "/vip1/activate",
  "/vip1/meet-list",
  "/vip1/online-request",
  "/api/posts/app-list",
  "/api/posts/all-app-list",
  "/api/posts/ingest-response",
  "/api/posts/search",
];
const LIST_PATHS = new Set([
  "/api/posts/app-list",
  "/api/posts/all-app-list",
  "/api/posts/search",
]);
const LIST_KEYS = [
  "moment_list",
  "posts",
  "post_list",
  "list",
  "items",
  "records",
  "data",
  "rows",
  "result",
];
const SEARCH_PARAMS = ["q", "search", "keyword", "id", "title", "name"];
const TEXT_FIELDS = [
  "id",
  "post_id",
  "postId",
  "moment_id",
  "momentId",
  "dynamic_id",
  "title",
  "name",
  "post_name",
  "postName",
  "content",
  "desc",
  "description",
];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return withCors(new Response(null, { status: 204 }));
    }

    if (!isHandledPath(url.pathname)) {
      return fetch(request);
    }

    const upstreamUrl = buildUpstreamUrl(url, env);
    const upstreamRequest = new Request(upstreamUrl, request);
    const token = env.JLY_TOKEN || DEFAULT_JLY_TOKEN;
    if (token && url.pathname === "/api/posts/ingest-response") {
      upstreamRequest.headers.set("authorization", `Bearer ${token}`);
    }
    const upstreamResponse = await fetch(upstreamRequest);
    const keyword = LIST_PATHS.has(url.pathname)
      ? firstQueryValue(url.searchParams, SEARCH_PARAMS).trim()
      : "";

    if (!keyword) {
      return withCors(upstreamResponse);
    }

    const contentType = upstreamResponse.headers.get("content-type") || "";
    if (!contentType.toLowerCase().includes("application/json")) {
      return withCors(upstreamResponse);
    }

    const body = await upstreamResponse.json();
    const filtered = filterResponse(body, keyword);
    const headers = new Headers(upstreamResponse.headers);
    headers.set("content-type", "application/json; charset=utf-8");

    return withCors(
      new Response(JSON.stringify(filtered), {
        status: upstreamResponse.status,
        statusText: upstreamResponse.statusText,
        headers,
      }),
    );
  },
};

function isHandledPath(pathname) {
  return PROXY_PATHS.includes(pathname);
}

function buildUpstreamUrl(inputUrl, env) {
  const upstreamBase = env.UPSTREAM_BASE || DEFAULT_UPSTREAM;
  const upstreamUrl = new URL(inputUrl);
  const baseUrl = new URL(upstreamBase);

  upstreamUrl.protocol = baseUrl.protocol;
  upstreamUrl.hostname = baseUrl.hostname;
  upstreamUrl.port = baseUrl.port;
  if (upstreamUrl.pathname === "/api/posts/search") {
    upstreamUrl.pathname = "/api/posts/all-app-list";
  }

  const token = env.JLY_TOKEN || DEFAULT_JLY_TOKEN;
  if (token && upstreamUrl.pathname.startsWith("/api/posts/") && !upstreamUrl.searchParams.has("token")) {
    upstreamUrl.searchParams.set("token", token);
  }

  return upstreamUrl.toString();
}

function firstQueryValue(searchParams, names) {
  for (const name of names) {
    const value = searchParams.get(name);
    if (value) {
      return value;
    }
  }
  return "";
}

function filterResponse(body, keyword) {
  const needle = normalize(keyword);
  const clone = structuredClone(body);
  const target = findBestList(clone);

  if (!target) {
    return clone;
  }

  const filtered = target.list.filter((item) => matchesItem(item, needle));
  target.owner[target.key] = filtered;
  updateTotals(clone, filtered.length);
  return clone;
}

function findBestList(root) {
  let best = null;

  walk(root, (owner, key, value) => {
    if (!Array.isArray(value) || value.length === 0) {
      return;
    }
    if (!value.every((item) => item && typeof item === "object" && !Array.isArray(item))) {
      return;
    }

    const keyScore = LIST_KEYS.includes(key) ? 10 : 0;
    const itemScore = value.slice(0, 5).reduce((score, item) => {
      return score + TEXT_FIELDS.filter((field) => item[field] !== undefined).length;
    }, 0);
    const score = keyScore + itemScore;

    if (!best || score > best.score) {
      best = { owner, key, list: value, score };
    }
  });

  return best;
}

function walk(value, visitor) {
  if (!value || typeof value !== "object") {
    return;
  }

  for (const [key, child] of Object.entries(value)) {
    visitor(value, key, child);
    walk(child, visitor);
  }
}

function matchesItem(item, needle) {
  return TEXT_FIELDS.some((field) => normalize(item[field]).includes(needle));
}

function normalize(value) {
  if (value === undefined || value === null) {
    return "";
  }
  return String(value).toLowerCase();
}

function updateTotals(value, total) {
  if (!value || typeof value !== "object") {
    return;
  }

  for (const [key, child] of Object.entries(value)) {
    if (["count", "total", "total_count", "totalCount"].includes(key)) {
      value[key] = total;
    } else {
      updateTotals(child, total);
    }
  }
}

function withCors(response) {
  const headers = new Headers(response.headers);
  headers.set("access-control-allow-origin", "*");
  headers.set("access-control-allow-methods", "GET,POST,OPTIONS");
  headers.set("access-control-allow-headers", "content-type,authorization");

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
