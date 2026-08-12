# WebSocket–SSE Idle Timeout Testbed

Testbed eksperimen untuk membandingkan ketahanan koneksi WebSocket dan Server-Sent Events (SSE) terhadap `proxy_read_timeout` pada middlebox Nginx. Seluruh node dijalankan sebagai container terpisah pada satu network Podman:

```text
client -> middlebox (Nginx :8080) -> server (Node.js :3000)
```

Log aplikasi disimpan sebagai JSON Lines di `logs/`, sedangkan packet capture tiap run disimpan di `captures/`. Kedua direktori tidak ikut masuk Git.

## Prasyarat

Jalur yang direkomendasikan hanya membutuhkan:

- Podman 5 atau lebih baru;
- Python 3 untuk ekspor CSV (tanpa package tambahan);
- ruang disk yang cukup untuk image dan berkas PCAP.

Di macOS/Windows, siapkan VM Podman satu kali:

```bash
podman machine init
podman machine start
```

Lalu periksa lingkungan:

```bash
./scripts/testbed.sh doctor
```

Node.js, Nginx, dan tcpdump lokal tidak wajib. Semuanya tersedia di dalam image. `compose.yaml` juga disediakan untuk pengguna yang sudah memasang compose provider, tetapi skrip utama memakai perintah Podman langsung sehingga tidak bergantung pada `podman-compose`.

## Quick start

Build image dan jalankan satu skenario pendek:

```bash
./scripts/testbed.sh build
./scripts/testbed.sh run websocket 15 10 20 1
./scripts/testbed.sh run sse       15 10 20 1
./scripts/testbed.sh export
```

Format perintah `run` adalah:

```text
run <websocket|sse> <idle-timeout> <heartbeat> <idle-duration> <repetition>
```

Setiap nilai durasi menggunakan detik. Bila `idle-duration` dikosongkan, nilainya otomatis `idle-timeout + 15`. Skrip akan:

1. menjalankan server dengan interval heartbeat yang dipilih;
2. menjalankan Nginx dengan idle timeout yang dipilih;
3. menyalakan tcpdump di middlebox;
4. menjalankan klien dan menunggu periode idle;
5. menghentikan container tanpa menghapus log dan PCAP.

Untuk debugging manual:

```bash
./scripts/testbed.sh up 15 10
curl http://127.0.0.1:8080/health
./scripts/testbed.sh status
./scripts/testbed.sh down
```

## Matriks eksperimen

Matriks bawaan memakai timeout 15, 30, 60, dan 120 detik. Heartbeat 10 detik dipakai pada semua timeout; timeout 15 detik juga diuji dengan heartbeat 15 dan 20 detik. Setiap pasangan diuji untuk kedua implementasi.

Smoke run satu repetisi (12 run):

```bash
./scripts/testbed.sh matrix 1
```

Setelah memeriksa smoke data, arsipkan agar tidak bercampur dengan dataset utama:

```bash
./scripts/testbed.sh archive
```

Pengambilan data utama 10 repetisi (120 run):

```bash
./scripts/testbed.sh matrix 10
```

Jalankan smoke run lebih dahulu. Matriks penuh dapat berlangsung beberapa jam dan menghasilkan PCAP besar. Jangan menjalankan dua matriks secara bersamaan karena keduanya memakai nama container dan file log yang sama. Runner menolak `run-id` yang sudah ada agar raw data atau PCAP tidak tertimpa. Gunakan nomor repetisi lain, atau `archive` untuk memulai dataset baru; arsip lokal disimpan di `artifacts/`.

## Keluaran

Setelah `./scripts/testbed.sh export`:

- `hasil_mentah.csv`: gabungan seluruh event server dan klien;
- `hasil_ringkas.csv`: jumlah run, survival rate, mean, p95, p99, dan maksimum RTT per kombinasi;
- `captures/<run-id>.pcap`: packet capture tiap run;
- `logs/server.log` dan `logs/client.log`: data sumber yang harus dipertahankan.

Contoh validasi retransmisi bila `tshark` tersedia:

```bash
tshark -r captures/websocket_15s_hb10s_rep01.pcap \
  -Y 'tcp.analysis.retransmission' -T fields -e frame.number | wc -l
```

Arsipkan raw log, PCAP, commit Git, versi Podman (`podman version`), OS, tanggal/waktu, dan kondisi jaringan host bersama hasil penelitian. Jangan mengedit raw log setelah pengambilan data.

## Definisi metrik dan batas interpretasi

- `connection_survived_idle` bernilai benar bila koneksi tetap kontinu sampai probe. Untuk SSE, error/reconnect selama periode idle membuat nilainya salah walaupun `EventSource` berhasil tersambung kembali.
- `latency_ms` adalah round-trip time dari klien mengirim probe sampai acknowledgement diterima klien.
- Pada WebSocket, probe dan acknowledgement melewati koneksi WebSocket yang diuji.
- SSE bersifat satu arah. Probe SSE menggunakan HTTP POST terpisah ke `/probe`; karena itu RTT SSE tersebut adalah RTT HTTP request-response dan **tidak boleh diklaim sebagai latency pengiriman SSE yang setara langsung dengan WebSocket**. Perbandingan utama yang valid dari desain ini adalah survival/churn koneksi dan overhead heartbeat.
- Heartbeat adalah traffic jaringan dan akan mereset idle timer Nginx. Skenario `heartbeat < timeout` semestinya bertahan; skenario `heartbeat >= timeout` menguji kondisi batas dan potensi pemutusan. Gunakan hasil aktual dan PCAP, bukan asumsi ini, dalam analisis.
- `proxy_read_timeout` Nginx menguji perilaku application proxy, bukan timeout NAT/conntrack kernel. Jangan menyebut hasilnya sebagai pengukuran NAT tanpa eksperimen terpisah.

## Pemeriksaan sebelum pengambilan data utama

- Pastikan kedua smoke run menghasilkan event `scenario_result` di `logs/client.log`.
- Pastikan PCAP tidak kosong dan berisi traffic port 8080/3000.
- Pastikan waktu host stabil; jangan mengubah jam sistem selama eksperimen.
- Pastikan jumlah run unik di `hasil_ringkas.csv` sesuai matriks.
- Simpan konfigurasi dan commit Git yang sama untuk seluruh repetisi.

## Struktur penting

```text
Containerfile                 image Node untuk server dan klien
compose.yaml                  alternatif jika compose provider tersedia
nginx/Containerfile           image Nginx dengan tcpdump
nginx/default.conf.template   timeout dikendalikan lewat IDLE_TIMEOUT
server/index.js               endpoint /ws, /events, /probe, /health
client/run_test.js            runner satu skenario dan instrumentasi
scripts/testbed.sh            lifecycle, run, matriks, dan capture
scripts/export-results.py     ekspor/rekap tanpa dependensi Python eksternal
```

Skrip PowerShell lama di `scripts/` tetap tersedia untuk lingkungan Windows lokal, tetapi jalur tersebut membutuhkan Node.js dan Nginx lokal serta tidak menyediakan isolasi/capture yang sama dengan jalur Podman.
