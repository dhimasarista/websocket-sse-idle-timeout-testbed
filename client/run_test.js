const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const EventSource = require("eventsource").EventSource;
const WebSocket = require("ws");

const ROOT = path.resolve(__dirname, "..");
const LOG_DIR = process.env.LOG_DIR || path.join(ROOT, "logs");
const LOG = process.env.CLIENT_LOG || path.join(LOG_DIR, "client.log");

fs.mkdirSync(LOG_DIR, { recursive: true });

function getArg(name, fallback) {
  const prefix = `--${name}=`;
  const found = process.argv.find((arg) => arg.startsWith(prefix));
  return found ? found.slice(prefix.length) : fallback;
}

const impl = getArg("impl", "websocket");
const idle = Number(getArg("idle", "20"));
const timeout = Number(getArg("timeout", "15"));
const heartbeat = Number(getArg("heartbeat", process.env.HEARTBEAT_INTERVAL || "10"));
const repetition = Number(getArg("rep", "1"));
const baseUrl = getArg("base-url", "http://127.0.0.1:8080");

function logEvent(event) {
  fs.appendFileSync(
    LOG,
    JSON.stringify({
      ...event,
      client_timestamp: Date.now(),
    }) + "\n"
  );
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function scenarioPayload() {
  return {
    message_id: crypto.randomUUID(),
    implementation_type: impl,
    idle_timeout_value: timeout,
    heartbeat_interval: heartbeat,
    repetition,
    probe: true,
    client_sent_timestamp: Date.now(),
  };
}

async function testWebSocket() {
  const wsUrl = baseUrl.replace(/^http/, "ws") + "/ws";

  await new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const failTimer = setTimeout(() => reject(new Error("WebSocket test timed out")), (idle + 20) * 1000);

    ws.on("open", async () => {
      logEvent({ event_type: "connect", implementation_type: "websocket" });
      await sleep(idle * 1000);
      const payload = scenarioPayload();
      logEvent({ event_type: "probe_send", implementation_type: "websocket", message_id: payload.message_id });
      ws.send(JSON.stringify(payload));
    });

    ws.on("message", (data) => {
      const parsed = JSON.parse(data.toString());
      logEvent({
        event_type: "probe_ack",
        implementation_type: "websocket",
        message_id: parsed.message_id,
        latency_ms: Date.now() - parsed.received_timestamp,
      });
      clearTimeout(failTimer);
      ws.close();
      resolve();
    });

    ws.on("close", (code) => {
      logEvent({ event_type: "close", implementation_type: "websocket", close_code: code });
    });

    ws.on("error", (err) => {
      logEvent({ event_type: "error", implementation_type: "websocket", detail: err.message });
      clearTimeout(failTimer);
      reject(err);
    });
  });
}

async function testSse() {
  const eventSource = new EventSource(`${baseUrl}/events`);

  await new Promise((resolve, reject) => {
    const failTimer = setTimeout(() => reject(new Error("SSE test timed out")), (idle + 20) * 1000);

    eventSource.onopen = async () => {
      logEvent({ event_type: "connect", implementation_type: "sse" });
      await sleep(idle * 1000);
      const payload = scenarioPayload();
      logEvent({ event_type: "probe_send", implementation_type: "sse", message_id: payload.message_id });

      fetch(`${baseUrl}/probe`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      })
        .then((res) => res.json())
        .then((body) => {
          logEvent({
            event_type: "probe_ack",
            implementation_type: "sse",
            message_id: body.message_id,
            latency_ms: Date.now() - body.received_timestamp,
          });
          clearTimeout(failTimer);
          eventSource.close();
          resolve();
        })
        .catch((err) => {
          clearTimeout(failTimer);
          eventSource.close();
          reject(err);
        });
    };

    eventSource.addEventListener("heartbeat", (event) => {
      logEvent({ event_type: "heartbeat", implementation_type: "sse", detail: event.data });
    });

    eventSource.onerror = (err) => {
      logEvent({ event_type: "error", implementation_type: "sse", detail: String(err.message || err) });
    };
  });
}

(async () => {
  if (!["websocket", "sse"].includes(impl)) {
    throw new Error("--impl must be websocket or sse");
  }

  if (impl === "websocket") {
    await testWebSocket();
  } else {
    await testSse();
  }

  console.log(`Completed ${impl} scenario: timeout=${timeout}s heartbeat=${heartbeat}s idle=${idle}s rep=${repetition}`);
})().catch((err) => {
  console.error(err);
  process.exit(1);
});

