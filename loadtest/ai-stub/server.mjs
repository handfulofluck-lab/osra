// Stand-in for the AI engine during a load test (loadtest/README.md). Answers POST /analyze with a fixed
// "safe" verdict after STUB_DELAY_MS (default 300 ms, about the real engine's p50) and GET /health with ok.
// It calls nothing: no Bedrock, no model, no spend. Node standard library only, so the Terraform sidecar
// can run it from the public node image with `node -e`, without building an image.
import http from "node:http";
const delay = Number(process.env.STUB_DELAY_MS ?? 300);
const port = Number(process.env.STUB_PORT ?? 8000);
http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") return res.end('{"ok":true}');
  if (req.method !== "POST" || !req.url.startsWith("/analyze")) { res.statusCode = 404; return res.end(); }
  req.resume();
  req.on("end", () => setTimeout(() => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ flagged: false, severity: "info", categories: { safe: 0.99 }, model_version: "loadtest-stub", path: "own" }));
  }, delay));
}).listen(port, () => console.log(`[ai-stub] listening on ${port}, delay ${delay} ms`));
