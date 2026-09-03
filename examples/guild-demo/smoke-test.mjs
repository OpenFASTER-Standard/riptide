#!/usr/bin/env node
// Standalone verification for the guild-demo page — NOT part of `mix test`/CI (needs a running
// dev server; the mock LLM server it also boots removes the *real-API-key* dependency, but a live
// Riptide instance is still required). Run manually: `node examples/guild-demo/smoke-test.mjs`.
import { chromium } from "playwright";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { rmSync } from "node:fs";
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

// `mix phx.server`'s own Ra/blob/capability-cache state is durable on disk across restarts
// (that's the whole point in real use) — but this script's own "genuinely fresh Riptide
// instance" premise (guild-a/guild-b must be claimable every run) needs a clean slate each time,
// confirmed necessary live: a second run without this hit a real 409 on signup, since the first
// run's own guild-a tenant was still on disk from priv/ra_data's own durable log.
function cleanDevState() {
  for (const dir of ["priv/ra_data", "priv/blob_data", "priv/capability_cache"]) {
    rmSync(path.join(RIPTIDE_ROOT, dir), { recursive: true, force: true });
  }
}

async function main() {
  cleanDevState();

  const mockLlm = await startMockLlmServer(MOCK_LLM_PORT);
  log(`mock LLM server up on :${MOCK_LLM_PORT}`);

  const server = spawn("mix", ["phx.server"], {
    cwd: RIPTIDE_ROOT,
    env: {
      ...process.env,
      // wasmtime (needed for Chapters 1/2's real Capability invocation) lives at
      // /work/.local/bin, not on this box's default PATH — confirmed the hard way: without this,
      // Capability.invoke/4 fails with `System.cmd("wasmtime", ...) ** (ErlangError) :enoent`.
      PATH: `/work/.local/bin:${process.env.PATH}`,
      PORT: String(RIPTIDE_PORT),
      LLM_API_BASE_URL: `http://localhost:${MOCK_LLM_PORT}`,
      LLM_API_KEY: "smoke-test-key",
      LLM_API_MODEL: "smoke-test-model",
      // The full 7-Chapter run drives well over 10 writes against Guild A's single tenant within
      // well under a minute — Riptide.WriteRateLimit's own default 10/minute is a real,
      // deliberate per-tenant safety limit, not a bug, but this script's own fully-controlled
      // instance needs it raised (confirmed live via a real 429 on Chapter 5's own second
      // concurrent Task submission before this was added). See config/dev.exs's own comment.
      WRITE_RATE_LIMIT: "1000",
    },
    stdio: "inherit",
  });

  let browser;

  try {
    await waitForReady(`${BASE_URL}/health/ready`);
    log("Riptide dev server ready");

    browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(`file://${path.join(__dirname, "index.html")}`);

    await runChapters(page);

    log("ALL CHAPTERS PASSED");
  } finally {
    // Without this, a failure above (any thrown error) skips straight to this finally without
    // ever reaching the old inline `browser.close()` — confirmed live: a failed run left chromium
    // (and its renderer/gpu/zygote child processes) running indefinitely, keeping this script's
    // own node process alive too, since Node won't exit while a child process still holds a pipe
    // open.
    if (browser) await browser.close();
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

  // Chapter 1
  await page.setInputFiles('#chapter1-wasm-input', path.join(__dirname, "capabilities/badge-qr-generator/badge-qr-generator.wasm"));
  await page.click('#chapter1-teach-button');
  await page.waitForSelector('#chapter1-use-section', { timeout: 10000 });
  await page.click('#chapter1-submit-button'); // uses the pre-filled default description
  await page.waitForSelector('.payoff svg', { timeout: 15000 });
  log("Chapter 1 passed");
  await page.click('button:has-text("Next chapter")');

  // Chapter 2
  await page.setInputFiles('#chapter2-wasm-input', path.join(__dirname, "capabilities/curse/curse.wasm"));
  await page.click('#chapter2-teach-button');
  await page.waitForSelector('#chapter2-use-section', { timeout: 10000 });
  await page.click('#chapter2-submit-button');
  await page.waitForSelector('.payoff:has-text("backfires")', { timeout: 15000 });
  log("Chapter 2 passed");
  await page.click('button:has-text("Next chapter")');

  // Chapter 3
  await page.fill('#chapter3-description-input', "make a badge that says Great job, Champion!");
  await page.click('#chapter3-submit-button');
  await page.waitForSelector('#chapter3-propose-button', { timeout: 15000 });
  await page.click('#chapter3-propose-button');
  await page.waitForSelector('#chapter3-approve-button', { timeout: 10000 });
  await page.click('#chapter3-approve-button');
  await page.waitForSelector('#chapter3-third-submit-button', { timeout: 10000 });
  await page.click('#chapter3-third-submit-button');
  await page.waitForSelector('.payoff:has-text("safely declined")', { timeout: 15000 });
  log("Chapter 3 passed");
  await page.click('button:has-text("Next chapter")');

  // Chapter 4
  await page.click('#chapter4-begin-guildb-button');
  await page.waitForSelector('#chapter4-admit-local-button', { timeout: 10000 });
  await page.click('#chapter4-admit-local-button');
  await page.waitForSelector('#chapter4-grant-public-button', { timeout: 10000 });
  await page.click('#chapter4-grant-public-button');
  await page.waitForSelector('#chapter4-discover-button', { timeout: 10000 });
  await page.click('#chapter4-discover-button');
  await page.waitForSelector('#chapter4-install-button', { timeout: 10000 });
  await page.click('#chapter4-install-button');
  await page.waitForSelector('#chapter4-approve-install-button', { timeout: 10000 });
  await page.click('#chapter4-approve-install-button');
  await page.waitForSelector('#chapter4-v2-button', { timeout: 10000 });
  await page.click('#chapter4-v2-button');
  await page.waitForSelector('.payoff:has-text("Already covered")', { timeout: 15000 });
  log("Chapter 4 passed");
  await page.click('button:has-text("Next chapter")');

  // Chapter 5
  await page.click('#chapter5-submit-both-button');
  await page.waitForSelector('.payoff:has-text("no double-loot")', { timeout: 20000 });
  log("Chapter 5 passed");
  await page.click('button:has-text("Next chapter")');

  // Chapter 6
  await page.click('#chapter6-begin-button');
  await page.waitForSelector('#chapter6-write-facts-button', { timeout: 10000 });
  await page.click('#chapter6-write-facts-button');
  await page.waitForSelector('#chapter6-ask-button', { timeout: 10000 });
  await page.click('#chapter6-ask-button');
  await page.waitForSelector('.payoff:has-text("swordFighting")', { timeout: 10000 });
  log("Chapter 6 passed");
}

main().catch((err) => {
  console.error("[smoke-test] FAILED:", err);
  process.exitCode = 1;
});
