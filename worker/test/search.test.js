import assert from "node:assert/strict";
import worker from "../src/index.js";

const originalFetch = globalThis.fetch;

const seenPaths = [];

globalThis.fetch = async (request) => {
  const url = new URL(request.url);
  seenPaths.push(`${url.origin}${url.pathname}${url.search}`);

  return new Response(
    JSON.stringify({
      code: 0,
      data: {
        total: 3,
        moment_list: [
          { id: 101, title: "alpha post" },
          { id: 202, title: "needle video" },
          { id: 303, title: "other" },
        ],
      },
    }),
    {
      headers: { "content-type": "application/json" },
    },
  );
};

try {
  const response = await worker.fetch(
    new Request("https://pee.jlyapp.cn/api/posts/all-app-list?q=needle"),
    {},
  );
  const body = await response.json();

  assert.equal(body.data.total, 1);
  assert.deepEqual(body.data.moment_list, [{ id: 202, title: "needle video" }]);

  await worker.fetch(new Request("https://pee.jlyapp.cn/vip1/meet-list?id=202"), {});
  await worker.fetch(new Request("https://pee.jlyapp.cn/vip1/online-request"), {});
  await worker.fetch(new Request("https://pee.jlyapp.cn/app-update.json"), {});
  await worker.fetch(
    new Request("https://pee.jlyapp.cn/api/posts/ingest-response", {
      method: "POST",
      body: "{}",
      headers: { "content-type": "application/json" },
    }),
    { JLY_TOKEN: "test-token" },
  );

  assert.deepEqual(seenPaths, [
    "https://pee.jlyapp.cn/api/posts/all-app-list?q=needle&token=EUDV6gd9cvJOWCBtKIfniR1zueqAjp5rSYxFso8yGX43mbZa",
    "https://pee.jlyapp.cn/vip1/meet-list?id=202",
    "https://pee.jlyapp.cn/vip1/online-request",
    "https://pee.jlyapp.cn/app-update.json",
    "https://pee.jlyapp.cn/api/posts/ingest-response?token=test-token",
  ]);

  console.log("search worker test passed");
} finally {
  globalThis.fetch = originalFetch;
}
