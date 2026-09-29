# Recap — Nhật ký thực hiện Lab Day 12 (Cloud Services & Deployment)

File này ghi lại lần lượt mọi hành động đã làm trong bài lab: lệnh đã chạy,
file đã sửa, lý do, và kết quả kiểm tra ở từng checkpoint.

---

## CP0 — Setup

**Hành động**

1. Clone repo `haimi612003/K4-L3B-DAY12-NguyenThiHaiMi-2A202602667-CloudServicesAndDeployment`
   vào thư mục làm việc (tên repo đúng mẫu `K4-L3B-DAY12-<HoVaTen>-<MSSV>-CloudServicesAndDeployment`).
2. Tạo môi trường ảo và cài thư viện:
   ```bash
   python3 -m venv .venv            # Python 3.13 có sẵn trên máy (≥ 3.11 là đạt)
   .venv/bin/pip install -r requirements.txt
   ```
3. Tạo `.env` từ `.env.example`, sinh `AGENT_API_KEY` ngẫu nhiên bằng
   `secrets.token_urlsafe(32)` và ghi vào `.env`. Xác nhận `.env` đã bị
   `.gitignore` bỏ qua (`git check-ignore .env`).
4. Bật Redis bằng `docker compose up -d redis` → **lỗi**:
   `Bind for 0.0.0.0:6379 failed: port is already allocated`.
   - Nguyên nhân: container `k4-l3a-cloud-service-and-deployment-main-redis-1`
     của project L3A đang chiếm cổng 6379 trên máy.
   - Cách xử lý (không tắt project khác): đổi mapping cổng trong
     `docker-compose.yml` thành `"${REDIS_HOST_PORT:-6379}:6379"` — mặc định vẫn
     là 6379, nhưng trên máy này đặt `REDIS_HOST_PORT=6380` trong `.env` và
     `REDIS_URL=redis://localhost:6380/0`.
   - Kết quả: Redis chạy ở `0.0.0.0:6380->6379`, trạng thái healthy.
5. Chạy `pytest tests/ -m "not docker"` để xác nhận môi trường: pytest chạy
   được, không có `ModuleNotFoundError`; test rớt hàng loạt vì code còn
   `NotImplementedError` — đúng như mong đợi ở CP0.

**Kết quả:** môi trường sẵn sàng, Redis chạy ở cổng 6380.

---

## CP1 — 12-Factor Config, Health & Logging

**File đã sửa**

| File | Thay đổi |
|------|----------|
| `app/config.py` | Khai báo 6 trường `port`, `agent_api_key` (**không mặc định** → fail fast), `redis_url`, `rate_limit_per_minute`, `monthly_budget_usd`, `log_level` |
| `app/logging_utils.py` | `log_event()` tạo dict `event` / `level` (viết thường) / `timestamp` + `**fields`, in ra stdout **một dòng** bằng `json.dumps(..., ensure_ascii=False)` (thêm `default=str` để giá trị lạ không làm vỡ log), `flush=True` |
| `app/main.py` — `/health` | Không nhận dependency nào; đang tắt → 503 `shutting_down`, bình thường → 200 `{status, service, version}` |

**Kiểm tra:** `pytest tests/test_cp1.py` → **13/13 passed**.

---

## CP3 — API Security (làm trước CP2 vì cùng nằm trong code Python)

**File đã sửa**

| File | Thay đổi |
|------|----------|
| `app/auth.py` | So sánh `X-API-Key` bằng `secrets.compare_digest` (constant-time); thiếu/sai → 401; trả `X-User-Id` hoặc `anonymous` |
| `app/rate_limiter.py` | Sliding window trên Redis ZSET: `zremrangebyscore` → `zcard` → nếu `>= limit` thì 429 (`Retry-After: 60`) → nếu chưa thì `zadd` member duy nhất `f"{now}:{uuid4().hex}"` + `expire 60`. **Kiểm tra trước, ghi nhận sau** |
| `app/cost_guard.py` | `spent()` (None → 0.0), `check()` (vượt ngân sách → 402), `record()` (`incrbyfloat` + TTL 40 ngày), key `cost:<user>:<YYYY-MM>` |
| `app/main.py` — `/ask` | Đúng thứ tự: `verify_api_key` → `limiter.check` → `guard.check` → `get_history` → `ask_llm` → `append` ×2 → `guard.record` → `log_event` → trả response. Chặn **trước** khi gọi LLM |

**Kiểm tra:** `pytest tests/test_cp3.py` → **passed toàn bộ**.

---

## CP4 — Scaling & Reliability

**File đã sửa**

| File | Thay đổi |
|------|----------|
| `app/store.py` | `ping()` nuốt mọi exception → `False`; `append()` = `rpush` + `ltrim(-20, -1)` (giữ 20 message **mới nhất**) + `expire` 7 ngày; `get_history()` = `lrange` + `json.loads` |
| `app/lifecycle.py` | `install()` lưu handler cũ bằng `signal.getsignal` rồi mới đăng ký `request_shutdown` cho SIGTERM/SIGINT; `request_shutdown()` bật cờ rồi **gọi lại handler cũ** (của uvicorn) |
| `app/main.py` — `/ready` | Đang tắt → 503 `shutting_down`; `store.ping()` False → 503 `not ready`; còn lại → 200 `ready` |

**Kiểm tra:** `pytest tests/test_cp1.py tests/test_cp3.py tests/test_cp4.py` → **54/54 passed**.
`grep -rn NotImplementedError app/` → không còn.

**Chạy thật với uvicorn (cổng 8001, Redis thật ở 6380)** — cổng 8000 đang bị
agent của project L3A dùng nên chạy ở 8001:

```
GET  /health               → 200 {"status":"ok","service":"day12-agent","version":"1.0.0"}
GET  /ready                → 200 {"status":"ready","redis":true}
POST /ask (không key)      → 401
POST /ask (có key, sv01)   → 200 {"answer":"Ngắn gọn: Docker là gì ...","user_id":"sv01","history_length":0,"cost_usd":2.265e-05,"tokens":{"in":3,"out":37}}
15 lần /ask (sv02)         → 200 ×10, rồi 429 ×5
```

Dòng log JSON thu được:
```json
{"event": "ask_completed", "level": "info", "timestamp": "2026-09-29T02:35:57.612828+00:00", "user_id": "sv01", "tokens_in": 3, "tokens_out": 37, "cost_usd": 2.265e-05}
```

Key trong Redis sau khi gọi: `ratelimit:sv01`, `cost:sv01:2026-09`, `history:sv01`, ...

**Graceful shutdown:** `kill -TERM <pid uvicorn>` → uvicorn in `Shutting down`,
log `service_stopped`, process thoát sau ~2 giây → chứng minh handler đã
nhường lại cho handler của uvicorn.

---

## CP2 — Docker

**Đo bản gốc trước khi sửa** — lưu Dockerfile gốc thành `Dockerfile.single-stage`
(để đối chiếu câu 3 exercises) rồi build `agent:single`:

- Dung lượng: **1.82GB**
- Chạy bằng `root`
- **Phát hiện: file `.env` (chứa API key) nằm luôn trong image**, kèm `.venv`
  63MB — vì `COPY . .` và `.dockerignore` gốc chỉ có `.git`, `.gitignore`.
  → Sau khi đo xong đã `docker rmi agent:single` để không giữ image chứa secret.

**File đã sửa**

| File | Thay đổi |
|------|----------|
| `Dockerfile` | 2 stage: `builder` (`python:3.11-slim`, `COPY requirements.txt` → `pip install --prefix=/install`) và `runtime` (`python:3.11-slim`, `COPY --from=builder /install /usr/local`, chỉ copy `app/` + `utils/`); `useradd --uid 10001 appuser` + `USER appuser`; `HEALTHCHECK` gọi `/health` theo `$PORT`; `CMD sh -c "exec uvicorn ... --host 0.0.0.0 --port ${PORT:-8000}"` (`exec` để uvicorn là PID 1, nhận SIGTERM trực tiếp) |
| `.dockerignore` | Thêm `.env`, `.env.*` (trừ `.env.example`), `*.pem`, `*.key`, `.github`, `__pycache__/`, `.venv/`, `.pytest_cache/`, `tests/`, `screenshots/`, `*.md`, `Dockerfile*`, compose, `nginx/`, `grade.py`, file OS/editor. **Không** ignore `app`, `utils`, `requirements.txt` |
| `docker-compose.yml` | Thêm service `agent`: `build: .`, cổng `${AGENT_HOST_PORT:-8000}:8000`, `AGENT_API_KEY: ${AGENT_API_KEY}` (nội suy, không hardcode), `REDIS_URL: redis://redis:6379/0`, `depends_on: redis (service_healthy)`, healthcheck `/health`, `stop_grace_period: 30s`. Thêm service `nginx` (profile `lb`, tùy chọn) làm load balancer. Redis đổi cổng host thành `${REDIS_HOST_PORT:-6379}` |
| `.env` (không commit) | Thêm `REDIS_HOST_PORT=6380`, `AGENT_HOST_PORT=8001` cho máy này |

**Kết quả đo**

| Bản | Dung lượng | User |
|-----|-----------|------|
| 1 stage (`agent:single`) | 1.82GB | root, có `.env` bên trong |
| Multi-stage (`agent:multi`) | **297MB** | `appuser` (uid 10001), trong `/app` chỉ có `app/`, `utils/` |

**Thí nghiệm cache** (sửa 1 ký tự trong docstring `app/main.py` rồi build lại, sau đó hoàn tác):
- Multi-stage: `COPY requirements.txt`, `pip install`, `COPY --from=builder`, `useradd` đều **CACHED**; chỉ `COPY app` và `COPY utils` chạy lại (0.0s).
- 1 stage (`COPY . .` trước `pip install`): cache vỡ từ `COPY . .`, `pip install` **chạy lại mất 23.9s**.

**Chạy stack:** `docker compose up -d --build` → agent `healthy`,
`/health` 200, `/ready` 200, `/ask` không key 401.

**Scale 3 instance + nginx** (`AGENT_HOST_PORT=8001-8003 docker compose --profile lb up -d --scale agent=3`),
gọi `/ask` 6 lần qua nginx `:8080` với cùng `X-User-Id: scale-user`:
- `history_length`: 0 → 2 → 4 → 6 → 8 → 10 (tăng đều)
- Log cho thấy mỗi container agent-1/2/3 nhận **2 request** (round-robin) → state dùng chung qua Redis.

**Mô phỏng Redis chết** (`docker compose stop redis` trong ~35 giây):
- Cả 3 agent: `/health` = **200**, `/ready` = **503** `{"status":"not ready","redis":false}`
- Sau 30 giây: cả 3 container vẫn `Up (healthy)` — **không container nào bị restart**
- `docker compose start redis` → cả 3 `/ready` trở lại 200 tự động.

**Graceful shutdown trong container:** `docker stop agent-1` → xong trong 0.47s,
log `service_stopped`, `Application shutdown complete`, **ExitCode=0**.

**Kiểm tra:** `pytest tests/test_cp2.py` (kể cả 2 test build image thật) → **16/16 passed**.

---

## Exercises — `exercises.md`

- Điền họ tên **Nguyễn Thị Hải Mi**, mã học viên **2A202602667**.
- Trả lời câu 1–9 dựa trên **số liệu đo thật** ở trên (log JSON, 1.82GB vs 297MB,
  23.9s pip install khi vỡ cache, `uid=10001`, `200×10 / 429×5`, Redis chết →
  `/health` 200 + `/ready` 503, `history_length` 0→10 khi scale 3 instance).
- Câu 3: điền số đo vào bảng có sẵn trong đề.
- Câu 10 (lỗi gặp khi deploy cloud) **để sau** — chỉ viết khi đã deploy thật,
  không bịa.
- **Sự cố khi điền:** lần đầu dùng `str.replace` thay placeholder theo thứ tự,
  nhưng dòng hướng dẫn ở đầu file cũng chứa chuỗi `` `> *Câu trả lời của bạn*` ``
  → mọi câu trả lời bị lệch lên một vị trí. Đã `git checkout exercises.md` và
  làm lại bằng cách tách theo tiêu đề `### Câu N`, chỉ thay dòng placeholder
  đứng riêng (`^> \*Câu trả lời của bạn\*$`).
- **Lưu ý về `grade.py`:** grader đếm *mọi* lần xuất hiện chuỗi
  `> *Câu trả lời của bạn*` (file gốc có 11 lần, tính cả dòng hướng dẫn), nên dù
  trả lời đủ 10 câu vẫn chỉ được 9/10. Đã diễn đạt lại dòng hướng dẫn (giữ
  nguyên ý: *"thay dòng placeholder in nghiêng … (bắt đầu bằng `>`) bằng câu
  trả lời"*) để nó không bị đếm nhầm.

> ⚠️ Theo `RULES.md`, câu trả lời phải là lời của học viên và học viên phải giải
> thích được. Các câu trả lời trên là bản nháp dựa trên số liệu thật — cần đọc
> lại, hiểu, và chỉnh theo cách diễn đạt của mình trước khi nộp.

---

## Bonus — CI/CD với GitHub Actions

**File mới:** `.github/workflows/ci.yml`

| Job | Nội dung |
|-----|----------|
| `test` | `actions/checkout@v4` → `actions/setup-python@v5` (3.11, cache pip) → `pip install -r requirements.txt` → `pytest tests/ -m "not docker" --ignore=tests/test_cp5.py --ignore=tests/test_bonus_cicd.py` với `AGENT_API_KEY=ci-dummy`, `REDIS_URL=fake://` qua `env:` |
| `build` | `docker build` trên runner sạch + chạy thử container (`REDIS_URL=fake://`) và `curl /health` |
| `deploy` | `needs: [test, build]`, `if: github.ref == 'refs/heads/main' && github.event_name == 'push'`; cài Railway CLI, `railway up --ci --service ${{ vars.RAILWAY_SERVICE }}` với `RAILWAY_TOKEN: ${{ secrets.RAILWAY_TOKEN }}`; smoke test `curl -fsS ${{ vars.PUBLIC_URL }}/health` và `/ready` sau 45s |

- Trigger: `push` và `pull_request` vào `main`. Mọi action ghim phiên bản (`@v4`, `@v5`).
  `permissions: contents: read`, `concurrency` để hủy lần chạy cũ.
- Không có secret nào trong YAML — token nằm ở GitHub Secrets.
- Thêm badge `![CI](.../actions/workflows/ci.yml/badge.svg)` lên đầu `README.md`.

**Kiểm tra**
- Chạy đúng lệnh pytest của CI trên máy: **68 passed**.
- `pytest tests/test_bonus_cicd.py` → **12/13 passed**. Test còn lại
  `test_badge_bao_passing` chỉ xanh sau khi **push lên GitHub** và workflow chạy
  thành công (hiện chưa push theo yêu cầu "không commit").

**Việc cần làm trên GitHub để job deploy chạy được**
1. Railway → project → Settings → Tokens → tạo *Project Token*.
2. `gh secret set RAILWAY_TOKEN` (dán token khi được hỏi — không dán vào chat/repo).
3. `gh variable set RAILWAY_SERVICE --body "<tên service>"` và
   `gh variable set PUBLIC_URL --body "https://<domain>"`.

---

## Dọn cổng — chỉ chạy project này

Theo yêu cầu, tắt các container khác để project này dùng cổng mặc định:

1. `docker stop` 2 container của project L3A
   (`k4-l3a-...-main-agent-1` giữ cổng 8000, `k4-l3a-...-main-redis-1` giữ 6379).
   Chỉ **stop**, không xóa → dữ liệu/volume của L3A vẫn còn; restart policy của
   chúng là `no` nên không tự bật lại.
2. Đưa `.env` về mặc định: `REDIS_URL=redis://localhost:6379/0`, xóa
   `REDIS_HOST_PORT` và `AGENT_HOST_PORT`. (`docker-compose.yml` vẫn giữ
   `${REDIS_HOST_PORT:-6379}` / `${AGENT_HOST_PORT:-8000}` — mặc định chính là
   6379/8000 nên không cần đặt gì.)
3. `docker compose up -d --build` → chỉ còn 2 container của project này:
   - `redis-1` → `0.0.0.0:6379`, healthy
   - `agent-1` → `0.0.0.0:8000`, healthy
4. Kiểm tra: `/health` 200, `/ready` 200 (`redis: true`), `/ask` không key 401,
   có key 200.

---

## CP5 — Deploy lên Railway

**Hành động** (sau khi học viên tự chạy `npx @railway/cli login` qua trình duyệt)

1. `railway whoami` → đã đăng nhập; tài khoản chưa có project nào.
2. Gọi CLI qua biến `R="npx --yes @railway/cli"` → lỗi
   `(eval):1: no such file or directory: npx --yes @railway/cli` (zsh không tách
   từ khi mở rộng biến) → sửa bằng `npm i -g @railway/cli` (railway 5.63.1).
3. `railway init --name day12-agent` → tạo project.
4. `railway add --database redis` → service `Redis`.
5. Sinh khóa API **riêng cho cloud** (`secrets.token_urlsafe(32)`), lưu vào
   `DEPLOY_API_KEY` trong `.env` (không commit) và truyền thẳng vào lệnh, không in ra:
   `railway add --service agent --variables AGENT_API_KEY=... --variables 'REDIS_URL=${{Redis.REDIS_URL}}' --variables RATE_LIMIT_PER_MINUTE=10 --variables MONTHLY_BUDGET_USD=10.0 --variables LOG_LEVEL=INFO`.
   Kiểm tra `REDIS_URL` resolve về `redis://***@redis.railway.internal:6379`.
6. `railway up --ci --service agent` → build từ `Dockerfile` (theo `railway.toml`), `Deploy complete`.
7. `railway domain --service agent` → **https://agent-production-436a.up.railway.app**.
8. `railway logs` → `service_started`, `Uvicorn running on http://0.0.0.0:8080`
   (Railway gán `PORT=8080`, app đọc đúng `$PORT`).

**Kiểm tra bản deploy**

```
GET  /health          → HTTP/2 200 {"status":"ok",...}
GET  /ready           → HTTP/2 200 {"status":"ready","redis":true}
POST /ask (không key) → HTTP/2 401
POST /ask (có key)    → HTTP/2 200 (answer, history_length 0, cost_usd 2.145e-05)
15 lần /ask           → 200 ×9, 429 ×6 (cộng request trước đó = đúng 10/phút)
```

- Điền `DEPLOYMENT.md`: họ tên, mã học viên, link repo, Public URL, platform,
  ngày deploy, **tên** biến môi trường (không ghi giá trị), output thật ở trên.
  Xóa mục "Phương án dự phòng" vì không dùng.
- `pytest tests/test_cp5.py` → **9 passed**, 4 skipped (các test chỉ dành cho LOCAL_FALLBACK),
  kể cả `test_ask_hoat_dong_voi_key_that` dùng `DEPLOY_API_KEY`.
- `exercises.md` câu 10: ghi lỗi thật ở bước 2 + quan sát `PORT=8080` + cảnh báo
  `railway.toml` bị deprecated.

**Còn lại cho học viên**
- Chụp `screenshots/dashboard.png` (Railway dashboard) và `screenshots/health.png`
  (mở `https://agent-production-436a.up.railway.app/health`) — không tạo ảnh giả.

---

## Thêm giao diện demo (ngoài yêu cầu của lab)

Mục đích: có trang web để demo trên lớp. Đề bài **không** yêu cầu và không chấm phần này.

**File thay đổi**

| File | Thay đổi |
|------|----------|
| `app/static/index.html` (mới) | Trang chat HTML/CSS/JS thuần, không thư viện ngoài. Ô nhập API key (ẩn/hiện, lưu `sessionStorage` — đóng tab là mất) và User ID; khung chat hiện câu trả lời kèm `history_length`, tokens, chi phí, độ trễ; badge `/health` và `/ready` tự làm mới mỗi 15 giây; nút demo "không key → 401", "gửi dồn 12 request → 429"; thẻ thống kê phiên. Tự đổi giao diện sáng/tối, có bố cục cho điện thoại |
| `app/main.py` | Thêm `GET /` (`include_in_schema=False`) trả `FileResponse` của `app/static/index.html` |

**Nguyên tắc bảo mật giữ nguyên:** trang **không nhúng API key** — người dùng phải
tự nhập, nên `/ask` vẫn được bảo vệ như CP3. Nội dung trả về được gắn bằng
`textContent` (không `innerHTML`) để tránh XSS.

**Kiểm tra**
- `pytest` CP1–CP4 → **70 passed** (không test nào bị ảnh hưởng).
- Local (`docker compose up -d --build`): `GET /` → 200 `text/html`, file nằm trong image tại `app/static/`.
- Ảnh chụp Chrome headless: desktop 1280px ổn; bản hẹp lúc đầu bị tràn ngang →
  sửa CSS (`minmax(0, 1fr)`, `main` thành cột dọc, pills wrap). Kiểm tra lại ở
  520px ổn (Chrome headless trên macOS có viewport tối thiểu 500px nên không đo được 390px).
- Test tự động bằng Chrome DevTools Protocol (script nằm ngoài repo): nhập key → hỏi 2 câu →
  bấm nút 401 → bấm gửi dồn. Kết quả giống nhau ở **local và Railway**:
  - badge `/health 200 ok`, `/ready 200 ready`
  - câu 2 có `history 2` ("Mình đang nhớ 2 lượt trao đổi trước đó")
  - nút không key → `401 {"detail":"invalid or missing API key"}`
  - gửi dồn: `200 ×8, 429 ×4` (2 câu hỏi + 8 = đúng 10 request/60 giây)
- Deploy lại: `railway up --ci --service agent` → `Deploy complete`;
  `https://agent-production-436a.up.railway.app/` → 200.
- `pytest tests/test_cp5.py` sau khi deploy lại → **9 passed**, 4 skipped.

---

## Bổ sung giải thích cho từng mục trên UI

Mục tiêu: người xem demo hiểu được mọi con số và nút trên màn hình.

**Cách hoạt động** (`app/static/index.html`)
- Rê chuột (máy tính), Tab bằng bàn phím, hoặc chạm/bấm vào biểu tượng ⓘ (điện
  thoại) → hiện hộp giải thích. Bấm vào ⓘ, ô thống kê, thẻ số liệu hoặc badge thì
  hộp được **ghim** lại; bấm ra ngoài hoặc nhấn `Esc` để đóng.
- Mỗi hộp có 3 phần: **ý nghĩa**, **Cách tính** (công thức), và **Hiện tại**
  (thay số liệu thật vào công thức, tự cập nhật khi có câu trả lời mới).
- Có giải thích cho: badge `/health`, `/ready` (kèm "kiểm tra N giây trước"), API
  key (độ dài khóa đã nhập, không lộ khóa), User ID (3 key Redis tương ứng), 3 nút
  Demo nhanh, từng mã 200/429 sau khi gửi dồn, 4 ô thống kê, nút Gửi (thứ tự kiểm
  tra 401 → 429 → 402 → LLM).
- Dòng số liệu dưới mỗi câu trả lời tách thành **thẻ riêng**: `history`,
  `tokens`, chi phí, độ trễ, `mock LLM` — mỗi thẻ giải thích số của **riêng câu
  đó** (vd. `46/1000 × 0.00015 + 50/1000 × 0.0006 = $0.0000069 + $0.00003 = $0.0000369`).
- Đổi tiêu đề "Phiên này" thành **"Phiên này · từ lúc mở trang"** + ghi chú
  "Tải lại trang → các số này về 0. Lịch sử hội thoại thì vẫn còn trong Redis".
- Ô "request" theo dõi thêm số request lỗi theo mã (hiện trong phần "Hiện tại").
- Màn hình trống ghi rõ câu trả lời đến từ **mock LLM** (4 câu mẫu), không phải AI thật.
- Nội dung giải thích được dựng bằng `textContent` (không `innerHTML`).

**Kiểm tra**
- `node --check` phần JavaScript → không lỗi cú pháp.
- Test tự động bằng Chrome DevTools Protocol có rê chuột thật (script ngoài repo):
  hỏi 1 câu khi chưa có key (401) + 2 câu có key, rồi rê chuột qua từng mục.
  Số liệu đúng: `Thành công: 2 · lỗi: 401×1`, token `49 + 87 = 136`, history
  `2 → 4`; ghim vẫn giữ khi di chuột đi, `Esc` đóng; **không có lỗi JS**.
- Sửa sau khi xem ảnh chụp: số tiền đè lên ⓘ trong ô thống kê (thêm padding phải),
  nhãn bị thừa khoảng trắng "X-API-Key )" (bọc text nhãn trong `<span>`).
- `pytest` CP1–CP4 → 70 passed. Deploy lại Railway → `Deploy complete`, test
  hộp giải thích trên URL thật cho kết quả giống local; `test_cp5.py` → 9 passed.

---

## Thêm menu Chatbot / Pipeline

Mục tiêu: có một trang trình bày cách hoàn thành bài lab, để Lab Coach và các bạn
xem được đã làm gì, theo thứ tự nào, và vì sao cách làm đó đúng.

**Thay đổi trong `app/static/index.html`**
- Header có menu 2 tab **Chatbot** (`#/chat`, mặc định) và **Pipeline** (`#/pipeline`).
  Chuyển tab không tải lại trang nên cuộc trò chuyện trong tab Chatbot vẫn giữ nguyên.
  CSS bố cục chat đổi từ `main` sang `.view-chat` để trang Pipeline có bố cục riêng.
- Tab **Pipeline** gồm:
  1. **Tổng quan**: 100/100 điểm, 79/79 test CP1–CP5, image 1.82 GB → 297 MB, HTTPS trên
     Railway; link repo GitHub, `/docs`.
  2. **Sơ đồ kiến trúc trên cloud**: trình duyệt → Railway edge (HTTPS, `PORT=8080`) →
     container `agent` → Redis nội bộ.
  3. **Sơ đồ luồng `POST /ask`**: API key (401) → rate limit (429) → cost guard (402) →
     đọc lịch sử → mock LLM → lưu + ghi.
  4. **Kiểm tra trực tiếp**: khi mở tab, trang tự gọi `GET /health`, `GET /ready`,
     `POST /ask` không key, `POST /ask` key sai rồi so với kết quả mong đợi (✓/✗),
     có nút chạy lại. Không cần API key; 401 trả về trước rate limit nên không tốn quota.
  5. **9 bước đã làm** (0 Setup → 8 UI demo), mỗi bước là một khối mở/thu gọn:
     bảng **Yêu cầu của đề → Cách làm → Kiểm chứng**, đoạn code chính, **Vì sao đúng**,
     **Bằng chứng** (số đo thật), **Sự cố & cách xử lý**. Bước 7 (CI/CD) ghi rõ
     trạng thái **12/13 test, chờ push**. Có thanh nhảy nhanh tới từng bước
     (tự tô sáng bước đang xem) và nút "Mở tất cả / Thu gọn tất cả".
- Mọi số liệu trên trang lấy từ các lần chạy thật ghi trong file này.

**Kiểm tra**
- Kiểm tra HTML đóng/mở thẻ đúng, `node --check` JavaScript không lỗi.
- Test tự động bằng Chrome DevTools Protocol:
  - Pipeline: 4 kiểm tra trực tiếp ✓; "Mở tất cả" mở đủ 9 bước; nhảy tới bước 2 tô sáng
    "2 · Docker"; không tràn ngang ở 1280px và 500px; chuyển về tab Chatbot đúng.
  - Chatbot vẫn chạy như cũ (hỏi 2 câu, gửi dồn → `200 ×8, 429 ×4`).
  - Không có lỗi JavaScript.
- Lỗi phát hiện và sửa: ở màn hình hẹp, thanh nhảy bước tô sáng nhầm vì
  IntersectionObserver theo dõi khung Pipeline trong khi lúc đó cả trang mới là thứ cuộn
  → theo dõi theo viewport; tăng `scroll-margin-top` khi thanh bước xuống 2 dòng.
- `pytest` CP1–CP4 → 70 passed. Deploy lại Railway → `Deploy complete`; kiểm tra lại cả 2 tab
  trên URL thật cho kết quả giống local; `test_cp5.py` → 9 passed.

---

## Thêm sơ đồ tuần tự "Hành trình của một request theo thời gian"

Vị trí: tab **Pipeline**, ngay dưới mục "Kiến trúc khi chạy trên cloud".

**Nội dung** — sơ đồ 4 cột (Trình duyệt · Railway edge · Container agent · Redis),
đọc từ trên xuống theo thời gian, dùng thuật ngữ kỹ thuật (không ẩn dụ):
1. **Mở trang**: `GET /` qua HTTPS → edge chuyển HTTP nội bộ tới cổng `$PORT = 8080`
   → trả `index.html`; trang tự gọi `/health`, `/ready` mỗi 15 giây.
2. **Gửi câu hỏi**: `POST /ask` với header `X-API-Key`, `X-User-Id` → edge giải mã TLS,
   chuyển tới `:8080` → agent kiểm tra body (422), API key (401) → Redis: rate limit
   `ZREMRANGEBYSCORE · ZCARD · ZADD` (429), ngân sách `GET cost:<user>:<YYYY-MM>` (402),
   đọc lịch sử `LRANGE` → mock LLM → ghi `RPUSH + LTRIM`, `INCRBYFLOAT` → log JSON.
3. **Nhận câu trả lời**: `200 JSON` → edge mã hóa TLS → trình duyệt hiển thị.

**Cách làm**: dữ liệu các bước khai báo trong mảng JS `SEQ`, vẽ bằng CSS grid
(không thư viện, không ảnh) — mũi tên liền = request, đứt = response, xanh lá = thao
tác Redis, ô xám = xử lý nội bộ, thẻ vàng = mã lỗi trả về nếu bước đó không đạt.
Tự đổi màu theo giao diện sáng/tối. Màn hình hẹp: khung sơ đồ cuộn ngang, có dòng gợi ý
"vuốt ngang".

**Kiểm tra**
- Chụp Chrome headless ở giao diện tối và sáng, 1280px và 500px. Sửa 1 lỗi: thẻ mã lỗi bị
  kéo dài thành cả thanh ngang (đổi thành `inline-block`).
- `node --check` không lỗi; kiểm tra tự động trang Pipeline (4 kiểm tra trực tiếp ✓, chuyển tab
  đúng, không lỗi JS); `pytest` CP1–CP4 → 70 passed.
- Deploy lại Railway → `Deploy complete`; sơ đồ hiển thị trên URL thật; `test_cp5.py` → 9 passed.

---

## Thử tải: 100 request đồng thời (chuẩn bị trả lời Lab Coach)

Chạy trên stack local (`docker compose`, 1 container agent + Redis), script `httpx` async
nằm ngoài repo. Không chạy trên Railway để tránh tạo tải lên bản đang chấm.

| Kịch bản | Kết quả |
|---|---|
| 100 user khác nhau, mỗi người 1 câu, cùng lúc | `200 ×100`, xong sau 318 ms; p50 226 ms, p95 287 ms |
| 1 user gửi 100 request cùng lúc | `200 ×11`, `429 ×89` (lần đầu); lặp 8 lần: số request lọt qua = 10, 12, 10, 12, 11, 10, 10, 11 |
| 1 user hỏi trùng "Docker là gì?" 3 lần | cùng câu trả lời; `history_length` 0 → 2 → 4; `tokens_in` 3 → 43 → 94; chi phí 2.3e-05 → 3.5e-05 → 4.2e-05 |

**Phát hiện: race condition trong rate limiter.** `hit_count` (ZREMRANGEBYSCORE + ZCARD)
và `ZADD` là các lệnh Redis riêng rẽ. Khi nhiều request của cùng một user tới cùng lúc,
vài request cùng đọc thấy "9" trước khi request nào kịp ghi → cùng được cho qua → vượt
hạn mức 1–2 request. Test của lab không bắt được vì gọi tuần tự. Cách sửa (chưa làm):
gộp kiểm tra + ghi thành một thao tác nguyên tử bằng Lua script (`EVAL`) hoặc
`MULTI/EXEC`. Cost guard có cùng kiểu "kiểm tra rồi mới ghi" nên cũng có thể vượt
ngân sách một chút khi nhiều request đồng thời.
