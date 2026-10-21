import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { captureScreenshot } from "../src/modules/evidence/screenshot.service.js";

test("does not report an HTTP error page as a captured screenshot", async () => {
  const server = createServer((_request, response) => {
    response.writeHead(404, { "content-type": "text/html" });
    response.end("<html><body>Not found</body></html>");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    assert.ok(address && typeof address !== "string");
    await assert.rejects(captureScreenshot(`http://127.0.0.1:${address.port}/`), /404/);
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});
