# Phiếu Phản Ánh — K4 Level 3B, Ngày 12

> **Bài làm cá nhân.** Trả lời bằng lời của chính bạn, dựa trên những gì bạn
> quan sát được khi chạy code — không sao chép đáp án của người khác.
>
> Cách trả lời: thay dòng placeholder in nghiêng *Câu trả lời của bạn* (bắt đầu bằng `>`) bằng câu trả lời.
> `grade.py` đếm số câu đã trả lời (15 điểm cho 10 câu).
>
> Họ và tên: Nguyễn Thị Hải Mi  Mã học viên: 2A202602667

---

### Câu 1 — Fail fast (CP1)

Trong `Settings`, `agent_api_key` không có giá trị mặc định nên app chết ngay
khi khởi động nếu thiếu biến môi trường. Hãy mô tả một tình huống cụ thể mà
việc "chết sớm" này cứu bạn, so với việc để mặc định `"changeme"`.

> Tình huống: deploy lên Railway nhưng quên thêm `AGENT_API_KEY` vào Variables.
> Nếu có mặc định `"changeme"`, container vẫn khởi động, health check xanh, và
> `/ask` được bảo vệ bằng một khóa mà ai đọc repo công khai cũng biết. Bot quét
> Internet dùng `X-API-Key: changeme` gọi thả ga, mình chỉ phát hiện khi thấy
> hóa đơn. Vì không có mặc định, `Settings()` ném `ValidationError:
> agent_api_key Field required` ngay lúc khởi động (test
> `test_thieu_api_key_thi_fail_fast` kiểm tra đúng điều này). Deploy fail, log
> chỉ thẳng biến bị thiếu, và lỗi hiện ra khi mình còn đang ngồi xem deploy.

---

### Câu 2 — Log cho máy đọc (CP1)

Chạy service và gọi `/ask` vài lần. Dán một dòng log JSON bạn thu được, rồi
nêu **hai** việc bạn làm được với dòng log đó mà `print("đã trả lời xong")`
không làm được.

> Dòng log thu được khi gọi `/ask` với `X-User-Id: sv01`:
>
> ```json
> {"event": "ask_completed", "level": "info", "timestamp": "2026-09-29T02:35:57.612828+00:00", "user_id": "sv01", "tokens_in": 3, "tokens_out": 37, "cost_usd": 2.265e-05}
> ```
>
> Hai việc làm được mà `print("đã trả lời xong")` không làm được:
> 1. **Lọc và tổng hợp theo trường**: ví dụ `jq 'select(.event=="ask_completed") | .cost_usd'`
>    hoặc query trên log platform để tính "user nào tiêu nhiều tiền nhất hôm nay"
>    (group theo `user_id`, cộng `cost_usd`), hay đếm số token vào/ra theo giờ.
> 2. **Đặt cảnh báo và tính tỷ lệ theo thời gian**: vì mỗi dòng có `timestamp`
>    ISO và `level`, hệ thống log có thể đếm số dòng `level=error` trong 5 phút
>    qua rồi báo động. Chuỗi `print` tự do thì không có cấu trúc để máy đếm.

---

### Câu 3 — Kích thước image (CP2)

Build cả hai phiên bản và ghi lại số đo thật:

```bash
docker build -f <Dockerfile-1-stage> -t agent:single .
docker build -t agent:multi .
docker images | grep agent
```

| Bản | Dung lượng |
|-----|-----------|
| 1 stage (bản đầu) | 1.82 GB (~1820 MB) |
| Multi-stage | 297 MB |

Giải thích: phần dung lượng chênh lệch đó là những gì?

> Khoảng 1.5 GB chênh lệch gồm:
> - **Base image đầy đủ `python:3.11`** (Debian đầy đủ, có gcc, header, git,
>   nhiều thư viện hệ thống) so với `python:3.11-slim`. Đây là phần lớn nhất.
> - **Build context rác**: bản 1 stage `COPY . .` nên chép cả `.venv` (63 MB,
>   đo bằng `du -sh /app/.venv` trong container), `tests/`, các file `.md`,
>   `.pytest_cache`. Tệ nhất là chép luôn `.env` chứa API key vào image.
> - **Cache của pip**: bản 1 stage không dùng `--no-cache-dir`.
>
> Multi-stage chỉ copy `/install` (thư viện đã cài) và hai thư mục `app/`,
> `utils/` sang stage runtime.

---

### Câu 4 — Thứ tự lệnh trong Dockerfile (CP2)

Sửa một ký tự trong `app/main.py` rồi build lại. Với Dockerfile của bạn, những
layer nào được dùng lại từ cache, layer nào phải chạy lại? Nếu bạn đặt
`COPY . .` lên trước `RUN pip install` thì kết quả khác thế nào?

> Thí nghiệm thật: sửa một ký tự trong docstring `app/main.py` rồi build lại.
> - **Dockerfile multi-stage của mình**: `COPY requirements.txt`, `RUN pip install`,
>   `COPY --from=builder`, `RUN useradd`, `WORKDIR` đều **CACHED**. Chỉ
>   `COPY app ./app` và các layer sau nó (`COPY utils`) chạy lại, mất khoảng 0 giây.
> - **Đặt `COPY . .` trước `pip install`** (Dockerfile 1 stage gốc): cache vỡ ngay
>   ở `COPY . .` vì nội dung thư mục đã đổi. Mọi layer sau nó đều phải chạy lại,
>   nên `pip install` chạy lại từ đầu, **mất 23.9 giây**, trong khi mình không
>   hề đổi `requirements.txt`.
>
> Docker vô hiệu hóa cache từ layer đầu tiên có input thay đổi trở đi, nên thứ
> ít thay đổi (dependency) phải đứng trước thứ hay thay đổi (code).

---

### Câu 5 — Vì sao không chạy bằng root (CP2)

Container mặc định chạy bằng root. Mô tả chuỗi sự kiện dẫn từ "một lỗ hổng
trong code Python của bạn" tới "kẻ tấn công có quyền cao trên máy host", và
lệnh `USER` cắt đứt chuỗi đó ở chỗ nào.

> Chuỗi sự kiện khi container chạy root:
> 1. Code Python có lỗ hổng (ví dụ deserialize dữ liệu không tin cậy, hoặc
>    một thư viện bị RCE) → kẻ tấn công chạy được lệnh shell trong container.
> 2. Tiến trình đó là **uid 0**. Trong container, root ghi được mọi file, cài
>    công cụ, đọc secret của mọi process.
> 3. Uid 0 trong container thường cũng là uid 0 trên host (nếu không bật user
>    namespace). Chỉ cần thêm một cấu hình sai (mount `/var/run/docker.sock`,
>    mount thư mục host, `--privileged`) hoặc một lỗ hổng kernel/runtime (kiểu
>    CVE runc) là thoát ra ngoài và **làm root trên máy host**.
>
> `USER appuser` cắt chuỗi này ở **bước 2**: shell của kẻ tấn công chỉ là
> uid 10001 (đã kiểm chứng: `id` trong image cho `uid=10001(appuser)`), không
> ghi được file hệ thống, không cài được gói. Kể cả thoát được container, trên
> host nó cũng chỉ là một user không có quyền gì.

---

### Câu 6 — Cửa sổ trượt (CP3)

Rate limit của bạn dùng sliding window 60 giây. Nếu thay bằng cách đếm theo
phút đồng hồ (reset lúc giây 00), một người dùng có thể gửi tối đa bao nhiêu
request trong 2 giây liên tiếp khi hạn mức là 10/phút? Giải thích cách đạt được
con số đó.

> Tối đa **20 request trong 2 giây**. Với cửa sổ cố định theo phút đồng hồ,
> bộ đếm reset đúng giây :00. Người dùng gửi 10 request lúc 10:00:59 (hết quota
> phút 10:00), đợi sang 10:01:00 bộ đếm về 0 rồi gửi tiếp 10 request lúc
> 10:01:00–10:01:01 (quota phút mới). Tổng cộng 20 request trong khoảng 2 giây,
> gấp đôi hạn mức mà vẫn "đúng luật".
>
> Sliding window của mình đếm các request trong 60 giây **tính ngược từ bây giờ**
> (`zremrangebyscore(key, 0, now - 60)` rồi `zcard`). Lúc 10:01:00, 10 request
> của 10:00:59 vẫn còn trong cửa sổ nên request thứ 11 bị 429. Kiểm tra thật:
> 15 lần gọi liên tiếp → `200 ×10` rồi `429 ×5`.

---

### Câu 7 — Rate limit và cost guard (CP3)

Hai cơ chế này khác nhau ở điểm nào? Cho một tình huống mà rate limit cho qua
nhưng cost guard phải chặn, và một tình huống ngược lại.

> **Rate limit** giới hạn *tần suất* (số request/60 giây, trả **429**) để chống
> spam hoặc bot và bảo vệ tài nguyên ngắn hạn. **Cost guard** giới hạn *tổng tiền*
> (USD/user/tháng, trả **402**) để chống cháy ngân sách dài hạn. Rate limit không
> quan tâm request to hay nhỏ, cost guard không quan tâm request nhanh hay chậm.
>
> - *Rate limit cho qua, cost guard chặn*: một user gửi đều đặn 5 request/phút
>   (dưới hạn mức 10), nhưng mỗi request dán một tài liệu dài vài chục nghìn token
>   và lặp lại suốt nhiều ngày. Tần suất hợp lệ nhưng `cost:<user>:<tháng>` vượt
>   10 USD, nên `/ask` trả 402. (Test `test_qua_http_thi_tra_402` đặt sẵn chi tiêu
>   999 USD, chỉ gọi 1 request vẫn bị 402.)
> - *Cost guard cho qua, rate limit chặn*: một script lỗi gọi `/ask` 15 lần liền
>   với câu hỏi ngắn "test". Mỗi lần chỉ tốn khoảng 0.00002 USD, ngân sách còn gần
>   như nguyên vẹn, nhưng từ lần thứ 11 đã bị 429 (đã quan sát được khi chạy thật).

---

### Câu 8 — /health khác /ready (CP4)

Nếu gộp hai endpoint làm một và cho nó kiểm tra Redis, chuyện gì xảy ra với cụm
3 container khi Redis mất kết nối 30 giây? Trả lời theo đúng thứ tự sự kiện.

> Nếu gộp làm một endpoint có kiểm tra Redis, theo thứ tự:
> 1. Redis mất kết nối → health check của **cả 3** container cùng lúc trả 503.
> 2. Sau vài lần fail liên tiếp (ví dụ `retries: 3`), orchestrator coi cả 3 là
>    unhealthy → **restart cả 3 cùng lúc**. Không còn instance nào phục vụ.
> 3. Container mới khởi động, health check vẫn fail vì Redis còn chết →
>    restart tiếp, vòng lặp crash/restart (thêm backoff, thêm thời gian chết).
> 4. Redis quay lại sau 30 giây nhưng các container đang ở giữa chu kỳ restart
>    nên phải chờ khởi động xong và qua health check mới nhận lại traffic.
>    Một sự cố Redis 30 giây biến thành downtime toàn hệ thống lâu hơn nhiều.
>
> Khi tách riêng (quan sát thật với `docker compose stop redis` khoảng 35 giây):
> cả 3 agent `/health` = 200, `/ready` = 503. Sau 30 giây vẫn `Up (healthy)`,
> **không container nào bị restart**. Load balancer chỉ ngừng gửi traffic dựa
> theo `/ready`. `docker compose start redis` xong thì cả 3 `/ready` tự về 200,
> không cần khởi động lại gì.

---

### Câu 9 — Stateless (CP4)

Chạy `docker compose up --scale agent=3` rồi gọi `/ask` nhiều lần với cùng một
`X-User-Id`. Quan sát `history_length` trong response. Nếu lịch sử được lưu
trong một dict Python thay vì Redis, bạn sẽ thấy con số đó thay đổi thế nào?

> Chạy thật `docker compose --profile lb up -d --scale agent=3` (có nginx
> round-robin), gọi `/ask` 6 lần qua nginx với cùng `X-User-Id: scale-user`:
> `history_length` = **0, 2, 4, 6, 8, 10**. Log cho thấy agent-1, agent-2,
> agent-3 mỗi container nhận đúng 2 request. Dù request rơi vào container nào,
> lịch sử vẫn liền mạch vì cả 3 cùng đọc và ghi `history:scale-user` trong Redis.
>
> Nếu lưu trong dict Python, mỗi container có một dict riêng trong RAM. Với
> round-robin A→B→C→A→B→C, con số sẽ là **0, 0, 0, 2, 2, 2**: mỗi container
> chỉ nhớ những lượt nó tự xử lý, agent "mất trí nhớ" ngẫu nhiên tùy request
> rơi vào đâu. Container nào restart thì lịch sử trong nó mất sạch về 0.

---

### Câu 10 — Deploy thật (CP5)

Ghi lại **một** lỗi bạn gặp khi deploy lên cloud (build fail, health check
timeout, sai REDIS_URL, app không đọc `$PORT`...): thông báo lỗi là gì, bạn
tìm ra nguyên nhân bằng cách nào, và sửa ra sao?

> Deploy lên Railway thành công ngay lần build đầu (build từ `Dockerfile`, log
> `Deploy complete`), nên lỗi thật mình gặp nằm ở **bước dùng Railway CLI**:
>
> - **Thông báo lỗi:** `(eval):1: no such file or directory: npx --yes @railway/cli`
>   khi mình gán `R="npx --yes @railway/cli"` rồi gọi `$R init --help`.
> - **Tìm nguyên nhân:** thông báo cho thấy shell coi *cả chuỗi* là tên một file
>   thực thi. zsh không tự tách từ (word splitting) khi mở rộng biến như bash, nên
>   `$R` là một "từ" duy nhất chứ không phải lệnh `npx` kèm 2 tham số.
> - **Cách sửa:** cài CLI global (`npm i -g @railway/cli`) để gọi thẳng `railway`,
>   sau đó `railway init` → `railway add --database redis` → `railway add --service agent
>   --variables ...` → `railway up --ci` → `railway domain` chạy bình thường.
>
> Một điểm mình kiểm chứng được nhờ log runtime: Railway gán `PORT=8080`
> (`Uvicorn running on http://0.0.0.0:8080`). Nếu app cố định cổng 8000 thay vì
> đọc `$PORT`, health check của Railway sẽ timeout. Ngoài ra CLI cảnh báo
> `railway.toml` (Config as Code) sẽ bị ngừng hỗ trợ từ 2026-12-01 và nên chuyển
> sang `.railway/railway.ts`.
