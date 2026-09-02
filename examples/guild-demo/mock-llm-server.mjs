#!/usr/bin/env node
// Minimal OpenAI-compatible chat-completions mock, for verifying the guild demo end-to-end
// without a real LLM vendor API key or non-deterministic output. NOT part of the shipped demo —
// testing infrastructure only, started by smoke-test.mjs (or standalone for manual poking).
import { createServer } from "node:http";

// Keyed by an exact substring of the incoming prompt's own "Task: <description>" line — the
// smoke test always submits these exact, known descriptions (a real visitor might type anything,
// which is fine: an unmatched prompt gets a 500, surfaced to the demo's own error handling, never
// silently wrong).
//
// IMPORTANT: the two badge-flavored completions share the exact same head predicate
// (badgeResult) and first head argument — Riptide.Derivation.AntiUnifier.check_heads_compatible/2
// requires an EXACT predicate match between two traces before they can be generalized at all
// (confirmed by reading anti_unifier.ex directly during planning), so Chapter 3's own "propose
// this as a pattern" step would fail with {:error, :no_common_structure} if these diverged.
const CANNED_COMPLETIONS = [
  {
    match: "make a badge that says Welcome, Adventurer!",
    rule:
      'badgeResult(<urn:riptide:demo:badge>, Result) :- capability(guild-demo-badge, "Welcome, Adventurer!", Result).',
  },
  {
    match: "make a badge that says Great job, Champion!",
    rule:
      'badgeResult(<urn:riptide:demo:badge>, Result) :- capability(guild-demo-badge, "Great job, Champion!", Result).',
  },
  {
    match: "try the cursed amulet",
    rule:
      'curseResult(<urn:riptide:demo:curse>, Result) :- capability(guild-demo-curse, Result).',
  },
];

function findCompletion(prompt) {
  const hit = CANNED_COMPLETIONS.find((c) => prompt.includes(c.match));
  return hit ? hit.rule : null;
}

export function startMockLlmServer(port) {
  const server = createServer((req, res) => {
    if (req.method !== "POST" || req.url !== "/chat/completions") {
      res.writeHead(404).end();
      return;
    }

    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const { messages } = JSON.parse(body);
      const prompt = messages[messages.length - 1].content;
      const rule = findCompletion(prompt);

      if (!rule) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: `mock-llm-server: no canned completion matches prompt: ${prompt}` }));
        return;
      }

      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ choices: [{ message: { content: rule } }] }));
    });
  });

  return new Promise((resolve) => {
    server.listen(port, () => resolve(server));
  });
}

// Runnable standalone: `node mock-llm-server.mjs [port]`
if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.argv[2] ?? 4100);
  await startMockLlmServer(port);
  console.log(`mock-llm-server listening on :${port}`);
}
