# Panduan Praktis Menjalankan Testbed (Bab III)

Ini alur kerja konkret dari nol sampai data siap dianalisis, mengikuti persis desain yang sudah ada di Bab III. Saya bagi jadi 8 tahap berurutan — jangan loncat tahap, karena tahap 6 (matriks pengujian) baru valid kalau tahap 1-5 sudah benar dan stabil.

## Tahap 0 — Cek dulu sebelum mulai

Sebelum instal apa pun, pastikan Ilham punya:
- Laptop/PC dengan minimal 8GB RAM (untuk jalankan 3 container sekaligus + tools monitoring)
- Docker Desktop atau Docker Engine terinstal
- Node.js versi LTS terbaru (untuk endpoint WebSocket/SSE)
- Wireshark + tcpdump

## Tahap 1 — Bangun 3 node dengan Docker Compose

Sesuai Gambar 3.1 (Node Klien, Node Middlebox, Node Peladen), jangan jalankan semuanya di satu proses — pisahkan pakai Docker network supaya lalu lintas benar-benar lewat "middlebox".

```yaml
# docker-compose.yml
version: "3.8"
services:
  server:
    build: ./server
    container_name: node_peladen
    networks: [testnet]

  middlebox:
    image: nginx:latest
    container_name: node_middlebox
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    ports:
      - "8080:8080"
    depends_on: [server]
    networks: [testnet]

  client:
    build: ./client
    container_name: node_klien
    depends_on: [middlebox]
    networks: [testnet]

networks:
  testnet:
    driver: bridge
```

Kenapa pakai Docker network terpisah (bukan `localhost`): supaya paket benar-benar melewati interface virtual dan bisa ditangkap `tcpdump` di container middlebox — kalau semua jalan di `localhost` yang sama, tidak ada "jalur jaringan" yang bisa diukur.

## Tahap 2 — Endpoint peladen (`/ws` dan `/events`)

Satu file server, dua endpoint, log format identik (sesuai Tabel 3.2).

```javascript
// server/index.js
const express = require("express");
const { WebSocketServer } = require("ws");
const fs = require("fs");

const app = express();
const LOG = "/logs/server.log";
const HEARTBEAT_INTERVAL = parseInt(process.env.HEARTBEAT_INTERVAL || "10") * 1000;

function logEvent(obj) {
  fs.appendFileSync(LOG, JSON.stringify({ ...obj, sent_timestamp: Date.now() }) + "\n");
}

// --- SSE endpoint ---
app.get("/events", (req, res) => {
  res.set({ "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
  res.flushHeaders();
  const id = crypto.randomUUID();

  const hb = setInterval(() => {
    res.write(": ping\n\n");
    logEvent({ message_id: crypto.randomUUID(), implementation_type: "sse", event_type: "heartbeat", payload_bytes: 8 });
  }, HEARTBEAT_INTERVAL);

  req.on("close", () => clearInterval(hb));
});

// --- WebSocket endpoint ---
const server = app.listen(3000);
const wss = new WebSocketServer({ server, path: "/ws" });
wss.on("connection", (ws) => {
  const hb = setInterval(() => {
    ws.ping();
    logEvent({ message_id: crypto.randomUUID(), implementation_type: "websocket", event_type: "heartbeat", payload_bytes: 2 });
  }, HEARTBEAT_INTERVAL);
  ws.on("close", () => clearInterval(hb));
});
```

Catatan penting: `HEARTBEAT_INTERVAL` diambil dari environment variable — supaya bisa diganti-ganti per skenario tanpa ubah kode (persis kebutuhan Tabel 3.1: interval 10/15/20 detik).

## Tahap 3 — Konfigurasi middlebox (idle timeout bertahap)

Ini bagian paling penting — di sinilah variabel bebas penelitian (idle timeout) benar-benar dikontrol.

```nginx
# nginx/nginx.conf
events {}
http {
    server {
        listen 8080;
        location /ws {
            proxy_pass http://server:3000;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_read_timeout 15s;   # <-- UBAH SESUAI SKENARIO: 15/30/60/120
        }
        location /events {
            proxy_pass http://server:3000;
            proxy_read_timeout 15s;  # <-- samakan dengan /ws
            proxy_buffering off;
        }
    }
}
```

Cara ganti nilai timeout tanpa rebuild image:
```bash
sed -i 's/proxy_read_timeout [0-9]*s/proxy_read_timeout 30s/' nginx/nginx.conf
docker compose restart middlebox
```

Kalau nanti mau simulasikan NAT/firewall level TCP (bukan cuma proxy HTTP), tambahkan container ketiga berbasis `alpine` dengan `iptables`/`conntrack`, dan atur:
```bash
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=15
```
(butuh container `--privileged` atau jalan di host langsung, karena `sysctl net.netfilter` butuh akses ke kernel host).

## Tahap 4 — Klien dengan periode idle terjadwal

Klien harus **sengaja diam** (tidak kirim data aplikasi) selama durasi tertentu untuk memicu idle timeout — bukan terus-menerus aktif.

```javascript
// client/index.js
const WebSocket = require("ws");
const EventSource = require("eventsource");

async function testWebSocket(idlePeriodSec) {
  const ws = new WebSocket("ws://middlebox:8080/ws");
  ws.on("open", () => {
    logEvent({ event_type: "connect", implementation_type: "websocket" });
    setTimeout(() => {
      // setelah idle, coba kirim pesan → di sinilah churn/retransmisi kelihatan
      ws.send(JSON.stringify({ probe: true }));
    }, idlePeriodSec * 1000);
  });
  ws.on("close", (code) => logEvent({ event_type: "reconnect", implementation_type: "websocket", close_code: code }));
  ws.on("error", (err) => logEvent({ event_type: "error", implementation_type: "websocket", detail: err.message }));
}
```

`idlePeriodSec` diset **lebih lama** dari nilai idle timeout middlebox yang sedang diuji, supaya efeknya benar-benar teramati (misal timeout 15 detik, idle period klien 25-30 detik).

## Tahap 5 — Jalankan tcpdump di middlebox (validasi silang independen)

Jangan hanya percaya log aplikasi — tangkap paket mentah supaya retransmisi dan TCP RST/FIN bisa divalidasi silang (sesuai 3.6).

```bash
docker exec node_middlebox tcpdump -i eth0 -w /captures/scenario_ws_15s_hb10s_rep01.pcap 'port 8080'
```

Jalankan ini **bersamaan** dengan setiap run skenario, matikan setelah durasi uji selesai. Setelah itu, ekstrak jumlah retransmisi dari file pcap:
```bash
tshark -r scenario_ws_15s_hb10s_rep01.pcap -Y "tcp.analysis.retransmission" | wc -l
```

## Tahap 6 — Eksekusi matriks pengujian (Tabel 3.1)

Ini bagian yang paling menyita waktu — 120 run (60/protokol × 2 protokol). Buat script otomatis, jangan dijalankan manual satu-satu:

```bash
#!/bin/bash
# run_all.sh
TIMEOUTS=(15 30 60 120)
HEARTBEATS_AT_15=(10 15 20)

for tm in "${TIMEOUTS[@]}"; do
  hbs=(10)
  if [ "$tm" == "15" ]; then hbs=("${HEARTBEATS_AT_15[@]}"); fi
  for hb in "${hbs[@]}"; do
    for rep in $(seq 1 10); do
      for impl in websocket sse; do
        echo "Run: impl=$impl timeout=$tm hb=$hb rep=$rep"
        sed -i "s/proxy_read_timeout [0-9]*s/proxy_read_timeout ${tm}s/" nginx/nginx.conf
        docker compose restart middlebox
        sleep 2
        HEARTBEAT_INTERVAL=$hb docker compose restart server
        docker exec node_middlebox tcpdump -i eth0 -w /captures/${impl}_${tm}s_hb${hb}s_rep${rep}.pcap &
        TCPDUMP_PID=$!
        docker compose run client node run_test.js --impl=$impl --idle=$((tm+15))
        kill $TCPDUMP_PID
      done
    done
  done
done
```

**Perkiraan waktu total**: kalau tiap run + jeda ≈ 3-5 menit, 120 run ≈ 6-10 jam eksekusi murni. Jangan coba selesaikan dalam sehari — pecah jadi beberapa sesi (misal per nilai idle timeout per hari), dan **catat kalau ada run yang gagal/perlu diulang**.

## Tahap 7 — Kumpulkan & bersihkan data

Setelah semua run selesai, gabungkan log JSON jadi satu tabel untuk dianalisis:

```python
import json, pandas as pd

records = []
with open("logs/server.log") as f:
    for line in f:
        records.append(json.loads(line))

df = pd.DataFrame(records)
df.to_csv("hasil_mentah.csv", index=False)

# Hitung tail latency per skenario
grouped = df[df.event_type == "data_message"].groupby(
    ["implementation_type", "idle_timeout_value"]
)["latency_ms"].agg(
    p95=lambda x: x.quantile(0.95),
    p99=lambda x: x.quantile(0.99)
).reset_index()
print(grouped)
```

Ini yang nanti dipindah ke Tabel 4.1-4.4 di Bab IV (ganti `[diisi]` dengan angka asli dari `grouped`).

## Tahap 8 — Checklist sebelum lapor ke pembimbing

- [ ] Semua 120 run selesai, tidak ada yang bolong (cek jumlah file `.pcap` = 120)
- [ ] Log server dan log klien bisa digabung by `message_id` tanpa data hilang
- [ ] Jumlah retransmisi dari `tshark` cocok kira-kira dengan jumlah `reconnect` di log aplikasi (kalau beda jauh, ada bug di instrumentasi)
- [ ] Simpan **raw log mentah** (`hasil_mentah.csv`, semua `.pcap`) sebagai lampiran wajib TA — jangan cuma simpan hasil olahan
- [ ] Baru setelah ini semua beres, minta saya bantu isi Tabel 4.1-4.4 dan tulis narasi Analisis (4.5) berdasarkan angka aslinya

Kalau nanti ada error spesifik pas eksekusi (misal container tidak bisa saling connect, atau `nf_conntrack` tidak bisa diubah dari dalam container), kirim pesan error-nya ke saya — saya bantu debug bagian itu.3