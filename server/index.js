const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const express = require("express");
const { WebSocketServer } = require("ws");

const ROOT = path.resolve(__dirname, "..");
const LOG_DIR = process.env.LOG_DIR || path.join(ROOT, "logs");
const LOG = process.env.SERVER_LOG || path.join(LOG_DIR, "server.log");
const PORT = Number(process.env.PORT || 3000);
const HEARTBEAT_INTERVAL = Number(process.env.HEARTBEAT_INTERVAL || 10) * 1000;

fs.mkdirSync(LOG_DIR, { recursive: true });

function logEvent(event) {
  fs.appendFileSync(
    LOG,
    JSON.stringify({
      ...event,
      sent_timestamp: Date.now(),
    }) + "\n"
  );
}

const app = express();
app.use(express.json({ limit: "1mb" }));

app.get("/health", (_req, res) => {
  res.json({ ok: true, heartbeat_interval_seconds: HEARTBEAT_INTERVAL / 1000 });
});

app.get("/events", (req, res) => {
  const connectionId = crypto.randomUUID();

  res.set({
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  res.flushHeaders();

  logEvent({
    connection_id: connectionId,
    message_id: crypto.randomUUID(),
    implementation_type: "sse",
    event_type: "connect",
    payload_bytes: 0,
  });

  const heartbeat = setInterval(() => {
    const payload = JSON.stringify({ type: "heartbeat", timestamp: Date.now() });
    res.write(`event: heartbeat\ndata: ${payload}\n\n`);
    logEvent({
      connection_id: connectionId,
      message_id: crypto.randomUUID(),
      implementation_type: "sse",
      event_type: "heartbeat",
      payload_bytes: Buffer.byteLength(payload),
    });
  }, HEARTBEAT_INTERVAL);

  req.on("close", () => {
    clearInterval(heartbeat);
    logEvent({
      connection_id: connectionId,
      message_id: crypto.randomUUID(),
      implementation_type: "sse",
      event_type: "close",
      payload_bytes: 0,
    });
  });
});

app.post("/probe", (req, res) => {
  const messageId = req.body?.message_id || crypto.randomUUID();
  const payload = JSON.stringify(req.body || {});

  logEvent({
    message_id: messageId,
    implementation_type: req.body?.implementation_type || "http",
    event_type: "data_message",
    payload_bytes: Buffer.byteLength(payload),
    idle_timeout_value: req.body?.idle_timeout_value,
    heartbeat_interval: req.body?.heartbeat_interval,
    repetition: req.body?.repetition,
  });

  res.json({ ok: true, message_id: messageId, received_timestamp: Date.now() });
});

const server = app.listen(PORT, "127.0.0.1", () => {
  console.log(`Server listening on http://127.0.0.1:${PORT}`);
});

const wss = new WebSocketServer({ server, path: "/ws" });

wss.on("connection", (ws) => {
  const connectionId = crypto.randomUUID();

  logEvent({
    connection_id: connectionId,
    message_id: crypto.randomUUID(),
    implementation_type: "websocket",
    event_type: "connect",
    payload_bytes: 0,
  });

  const heartbeat = setInterval(() => {
    ws.ping();
    logEvent({
      connection_id: connectionId,
      message_id: crypto.randomUUID(),
      implementation_type: "websocket",
      event_type: "heartbeat",
      payload_bytes: 2,
    });
  }, HEARTBEAT_INTERVAL);

  ws.on("message", (data) => {
    let payload = {};
    try {
      payload = JSON.parse(data.toString());
    } catch {
      payload = { raw: data.toString() };
    }

    const messageId = payload.message_id || crypto.randomUUID();
    logEvent({
      connection_id: connectionId,
      message_id: messageId,
      implementation_type: "websocket",
      event_type: "data_message",
      payload_bytes: Buffer.byteLength(data),
      idle_timeout_value: payload.idle_timeout_value,
      heartbeat_interval: payload.heartbeat_interval,
      repetition: payload.repetition,
    });

    ws.send(JSON.stringify({ ok: true, message_id: messageId, received_timestamp: Date.now() }));
  });

  ws.on("close", (code) => {
    clearInterval(heartbeat);
    logEvent({
      connection_id: connectionId,
      message_id: crypto.randomUUID(),
      implementation_type: "websocket",
      event_type: "close",
      payload_bytes: 0,
      close_code: code,
    });
  });
});

