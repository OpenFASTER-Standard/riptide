#!/usr/bin/env node
// Standalone verification for the guild-demo page — NOT part of `mix test`/CI (needs a running
// dev server; the mock LLM server it also boots removes the *real-API-key* dependency, but a live
// Riptide instance is still required). Run manually: `node examples/guild-demo/smoke-test.mjs`.
import { chromium } from "playwright";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { startMockLlmServer } from "./mock-llm-server.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RIPTIDE_ROOT = path.resolve(__dirname, "../..");
// Not Phoenix's own default 4000 — this box already has something else permanently bound there
// (confirmed live during planning: a direct socket-bind test failed with EADDRINUSE despite no
// beam/erl process of ours running). config/dev.exs now reads an optional PORT override for
// exactly this reason.
const RIPTIDE_PORT = 4321;
const BASE_URL = `http://localhost:${RIPTIDE_PORT}`;
const MOCK_LLM_PORT = 4100;

function log(msg) {
  console.log(`[smoke-test] ${msg}`);
}

async function waitForReady(url, attempts = 60) {
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`${url} never became ready`);
}

async function main() {
  const mockLlm = await startMockLlmServer(MOCK_LLM_PORT);
  log(`mock LLM server up on :${MOCK_LLM_PORT}`);

  const server = spawn("mix", ["phx.server"], {
    cwd: RIPTIDE_ROOT,
    env: {
      ...process.env,
      PORT: String(RIPTIDE_PORT),
      LLM_API_BASE_URL: `http://localhost:${MOCK_LLM_PORT}`,
      LLM_API_KEY: "smoke-test-key",
      LLM_API_MODEL: "smoke-test-model",
    },
    stdio: "inherit",
  });

  try {
    await waitForReady(`${BASE_URL}/health/ready`);
    log("Riptide dev server ready");

    const browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(`file://${path.join(__dirname, "index.html")}`);

    await runChapters(page);

    await browser.close();
    log("ALL CHAPTERS PASSED");
  } finally {
    server.kill();
    mockLlm.close();
  }
}

async function runChapters(page) {
  // Chapter 0
  await page.fill('#base-url-input', BASE_URL);
  await page.click('#begin-button');
  await page.waitForSelector('.payoff:has-text("Welcome, Alice")', { timeout: 10000 });
  log("Chapter 0 passed");
  await page.click('button:has-text("Next chapter")');

  // Later tasks append one more `log(...)` + assertion block here per Chapter, in order.
}

main().catch((err) => {
  console.error("[smoke-test] FAILED:", err);
  process.exitCode = 1;
});
