const BASE_URL = "http://localhost:4000";
const TENANT_ID = "story-demo";
const STORY_PATH = `/tenants/${TENANT_ID}/resources/the-story`;
const STREAM_ID = `https://riptide.example/tenants/${TENANT_ID}/resources/the-story`;
const TEXT_PRED = "http://schema.org/text";
const AUTHOR_PRED = "http://schema.org/author";
const TYPE_PRED = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type";
const CREATIVE_WORK = "http://schema.org/CreativeWork";

const GUEST_ADJECTIVES = [
  "Wandering", "Sleepy", "Curious", "Gentle", "Restless", "Radiant", "Quiet", "Daring",
];
const GUEST_NOUNS = ["Fox", "Comet", "Otter", "Lantern", "Sparrow", "Willow", "Ember", "Tide"];

function guestName() {
  let name = sessionStorage.getItem("guestName");
  if (!name) {
    const adjective = GUEST_ADJECTIVES[Math.floor(Math.random() * GUEST_ADJECTIVES.length)];
    const noun = GUEST_NOUNS[Math.floor(Math.random() * GUEST_NOUNS.length)];
    name = `the ${adjective} ${noun}`;
    sessionStorage.setItem("guestName", name);
  }
  return name;
}

function escapeTurtleLiteral(value) {
  // Triple-quoted Turtle string literals allow any character except an
  // unescaped backslash or the literal `"""` sequence — both vanishingly
  // rare in ordinary text, but escaped here for correctness against
  // arbitrary user input.
  return value.replace(/\\/g, "\\\\").replace(/"""/g, '\\"\\"\\"');
}

function unescapeTurtleLiteral(value) {
  return value.replace(/\\"\\"\\"/g, '"""').replace(/\\\\/g, "\\");
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function extractLiteral(turtle, predicateIri) {
  const pattern = new RegExp(`<${escapeRegExp(predicateIri)}>\\s+"""([\\s\\S]*?)"""`);
  const match = turtle.match(pattern);
  return match ? unescapeTurtleLiteral(match[1]) : null;
}

function renderLine(turtle) {
  const text = extractLiteral(turtle, TEXT_PRED);
  const author = extractLiteral(turtle, AUTHOR_PRED);
  if (text === null) return;

  const storyEl = document.getElementById("story");
  const lineEl = document.createElement("p");
  lineEl.className = "line";

  const textSpan = document.createElement("span");
  textSpan.className = "line-text";
  textSpan.textContent = text;

  const authorSpan = document.createElement("span");
  authorSpan.className = "line-author";
  authorSpan.textContent = `— ${author || "anonymous"}`;

  lineEl.appendChild(textSpan);
  lineEl.appendChild(authorSpan);
  storyEl.appendChild(lineEl);
  storyEl.scrollTop = storyEl.scrollHeight;

  document.getElementById("raw-data").textContent = turtle;
}

let lastSequence = 0;

function handleSseEvent(rawEvent) {
  let id = null;
  const dataLines = [];

  for (const line of rawEvent.split("\n")) {
    if (line.startsWith("id: ")) {
      id = parseInt(line.slice(4), 10);
    } else if (line.startsWith("data: ")) {
      dataLines.push(line.slice(6));
    }
  }

  if (id !== null) lastSequence = id;
  if (dataLines.length > 0) renderLine(dataLines.join("\n"));
}

async function subscribeOnce() {
  // Deliberately NOT the native EventSource API: browsers only let
  // EventSource set Last-Event-ID automatically, on its own automatic
  // reconnects — never on the very first connection — so there is no way
  // to ask a fresh EventSource for the backlog from cursor 0. fetch() lets
  // us set the header explicitly instead.
  const response = await fetch(
    `${BASE_URL}/streams/${encodeURIComponent(STREAM_ID)}/subscribe`,
    { headers: { "Last-Event-ID": String(lastSequence) } }
  );

  if (response.status === 409) {
    console.warn("Cursor fell out of the retention window — resetting to 0");
    lastSequence = 0;
    return;
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    let boundary;
    while ((boundary = buffer.indexOf("\n\n")) !== -1) {
      handleSseEvent(buffer.slice(0, boundary));
      buffer = buffer.slice(boundary + 2);
    }
  }
}

async function subscribeForever() {
  while (true) {
    try {
      await subscribeOnce();
    } catch (err) {
      console.error("SSE connection lost, reconnecting in 1s", err);
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
}

async function submitLine(text) {
  const lineId = `urn:uuid:${crypto.randomUUID()}`;
  const author = guestName();
  const additions =
    `<${lineId}> <${TYPE_PRED}> <${CREATIVE_WORK}> ;\n` +
    `  <${TEXT_PRED}> """${escapeTurtleLiteral(text)}""" ;\n` +
    `  <${AUTHOR_PRED}> """${escapeTurtleLiteral(author)}""" .\n`;

  const response = await fetch(`${BASE_URL}${STORY_PATH}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ additions, removals: "" }),
  });

  if (!response.ok) {
    throw new Error(`PATCH failed: ${response.status}`);
  }
}

document.getElementById("story-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = document.getElementById("line-input");
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  try {
    await submitLine(text);
  } catch (err) {
    console.error(err);
    alert("Couldn't add your line — is Riptide running? Check the console for details.");
  }
});

document.getElementById("toggle-raw").addEventListener("click", () => {
  document.getElementById("raw-data-container").classList.toggle("visible");
});

document.getElementById("guest-name").textContent = guestName();
subscribeForever();
