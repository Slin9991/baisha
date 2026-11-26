# Baisha36 線上訂房：架構方案（員工即時更新的訂房日曆）

適用 repo：`Slin9991/baisha`（純靜態網站，GitHub Pages 部署，原生 HTML/CSS/JS，中英雙語靠 `data-en` / `data-zh`）。

## 0. 一頁摘要

- **前端不改架構**：仍是靜態檔案，部署流程照舊。新增 `booking.html`（客人選日期下單）、`booking-status.html`（確認頁）、`admin/`（員工後台）。
- **後端用 Supabase**：PostgreSQL 資料庫 ＋ 員工登入 ＋ 即時同步 ＋ Edge Functions（寄信、防機器人）。GitHub Pages 本身無法儲存訂單，所以一定要有這一層。
- **防重複訂房由資料庫保證**：不是靠網頁把日期變灰。同一間房、重疊的夜晚，資料庫會直接拒絕第二筆，即使兩個人同一秒按下送出。
- **房型衝突自動處理**：每棟 Villa 拆成 1F / 2F / 3F 三個「區塊」，每個房型就是一組區塊。全館包棟會占用全部區塊，所以其他房型自動滿房。
- **所有東西都在 repo 裡**：資料表、權限、測試、Edge Functions 都用檔案管理，用 GitHub Actions 部署。
- **目前進度**：資料庫核心（`supabase/`）已寫好，在本機 PostgreSQL 16 通過 52 項檢查與同時搶訂測試。前端頁面、Edge Functions 尚未實作（見第 11 節）。

## 1. 先請您確認的假設（會直接影響資料）

我從 `index.html` 的房型文字推斷出下列實際房況，請逐項確認；不同的話，只需改 `seed.sql`，不用改程式。

| # | 假設 | 依據 |
|---|---|---|
| 1 | 莊園有 **2 棟 Villa（A、B）**，各 3 層 | 全館包棟 8 間臥室、一天一組；Villa 包棟「一天兩組」 |
| 2 | 每棟：1F 有 2 間臥室、2F 有 1 間（含廚房客廳）、3F 有 1 間 | 各房型的臥室配置文字 |
| 3 | 泳池景觀雙房 ＝ 1F；海景樓中樓雙房 ＝ 2F＋3F；Villa 小包棟 ＝ 1F＋2F（3F 不開放）；Villa 包棟 ＝ 1F＋2F＋3F；全館包棟 ＝ 兩棟全部 | 同上 |
| 4 | 同日換房：前一組退房日＝下一組入住日可以接續 | 入住 3PM／退房 11AM |
| 5 | 房價、訂金比例、最少住幾晚、待確認保留時數（預設 24 小時） | 網站上尚無資料，目前是空值／預設值 |

注意第 3 點的衝突關係：**Villa 小包棟（1F＋2F）與海景樓中樓（2F＋3F）共用 2F，同一棟不能同時賣**；但泳池景觀雙房（1F）與海景樓中樓（2F＋3F）可以同一棟同時賣給兩組客人。

## 2. 為什麼是 Supabase，不是 Google 試算表或 Firebase

| 需求 | Supabase（建議） | Google 試算表＋Apps Script | Firebase |
|---|---|---|---|
| 同時下單不重複 | 資料庫約束保證 | 靠程式鎖，較脆弱 | 需自己寫交易邏輯 |
| 「全館包棟」這種多區塊衝突 | SQL 一次處理 | 需手寫大量公式 | 需手寫 |
| 員工即時看到更新 | 內建 Realtime | 需輪詢 | 內建 |
| 員工登入與權限 | 內建 Auth＋RLS | 較難細分 | 內建 |
| 資料可備份、可遷移 | 標準 PostgreSQL | 試算表 | 專有格式 |

## 3. 系統架構

```
 客人瀏覽器（GitHub Pages：baisha36.co）            員工瀏覽器（/admin/）
   booking.html / booking-status.html                admin/index.html
        │ get_availability / quote_stay / get_booking     │ Email 登入（Supabase Auth）
        │ （anon key，只能呼叫唯讀函式）                    │ 讀寫訂單＋Realtime 即時更新
        │ POST create-booking（附 Turnstile 驗證）          │ staff_create_booking / staff_block
        ▼                                                  ▼
 ┌──────────────────────────── Supabase ─────────────────────────────┐
 │ Edge Functions：create-booking · on-booking-event · ical          │
 │ PostgreSQL：zones / room_types / bookings / booking_zones         │
 │   └ EXCLUDE 約束 ＝ 資料庫層防重複訂房                             │
 │ Auth＋RLS（誰能看什麼）· Realtime · pg_cron（逾時自動釋出）        │
 └──────────┬───────────────────────────────┬────────────────────────┘
            │ Email（Resend）               │ LINE Messaging API
            ▼                               ▼
       客人／員工信箱                      員工 LINE
```

核心觀念：**瀏覽器不能被信任**。客人端只能「讀公開資料」和「透過 Edge Function 送出申請」；價格、可訂與否、房型衝突全部在資料庫算。

## 4. 資料模型與規則

### 4.1 資料表（已在 `0001_booking_core.sql` 實作）

| 表 | 用途 |
|---|---|
| `zones` | 6 個區塊：A1 A2 A3 B1 B2 B3 |
| `room_types` | 5 個房型：名稱（中英）、人數上下限、最少晚數、基本房價、訂金比例 |
| `room_type_levels` | 每個房型用到一棟 Villa 的哪幾層 |
| `daily_prices` | 逐日價格覆蓋（假日、旺季）；沒有就用基本房價 |
| `bookings` | 訂單：狀態、日期、客人資料、金額、保留期限 |
| `booking_zones` | 每筆訂單占用哪些區塊、哪些夜晚。**EXCLUDE 約束在這裡** |
| `staff` | 員工白名單（對應 Supabase Auth 使用者） |
| `app_settings` | 設定，例如 `hold_hours` |

### 4.2 訂單狀態

```
客人送出 ──► pending（待確認，已保留日期，逾時自動釋出）
                │ 員工收到訂金、按「確認」
                ▼
            confirmed ──► cancelled（員工取消，日期立即釋出）
pending ──逾時──► expired
員工關房／外部平台日曆 ──► blocked
```

只有 `pending`、`confirmed`、`blocked` 會占用日期。這正好對應我們畫的兩個畫面：「訂房申請已送出（待確認）」與「訂房已確認」。

### 4.3 配房邏輯（`find_allocation`）

1. 找出此房型需要的區塊。單棟型房型會依序嘗試 A、B 兩棟。
2. 該棟需要的區塊在整段住宿期間都空著，才算可用。
3. 若兩棟都可用，**優先放進已經比較忙的那一棟**（best fit），讓另一棟保持完整，才賣得出 Villa 包棟或全館包棟。
4. 都不行就回傳「已滿」。

### 4.4 同一晚可以同時賣的組合

| | 全館 | Villa 包棟 | Villa 小包棟 | 泳池景觀雙房 | 海景樓中樓 |
|---|---|---|---|---|---|
| 全館 | ✗ | ✗ | ✗ | ✗ | ✗ |
| Villa 包棟 | ✗ | 最多 2 組 | 同棟 ✗，另一棟 ✓ | 另一棟 ✓ | 另一棟 ✓ |
| Villa 小包棟 | ✗ | 另一棟 ✓ | 最多 2 組 | 另一棟 ✓ | 另一棟 ✓ |
| 泳池景觀雙房 | ✗ | 另一棟 ✓ | 另一棟 ✓ | 最多 2 組 | 同棟 ✓ |
| 海景樓中樓 | ✗ | 另一棟 ✓ | 另一棟 ✓ | 同棟 ✓ | 最多 2 組 |

### 4.5 日期規則

- 住宿區間為 `[入住日, 退房日)`，所以 12/19 入住、12/21 退房占用 19、20 兩晚，21 日可接下一組。
- 「今天」一律以 Asia/Taipei 計算。
- 單筆最多 30 晚（可在函式內調整）。

## 5. Repo 檔案配置

```
baisha/
├─ index.html                 ［修改］各房型「洽詢此房型」改為連到 booking.html?room=<房型id>，保留聯絡我們區塊
├─ booking.html               ［新增］客人：選房型 → 選日期 → 填資料 → 送出
├─ booking-status.html        ［新增］客人：申請狀態／確認頁（即 Received、Main、Mobile 設計稿）
├─ config.js                  ［新增］SUPABASE_URL、anon key、Turnstile site key（皆為可公開值）
├─ js/
│  ├─ api.js                  ［新增］用 fetch 呼叫 Supabase（客人端不需任何 SDK）
│  ├─ calendar.js             ［新增］日期選擇元件
│  ├─ booking.js              ［新增］訂房流程
│  ├─ status.js               ［新增］狀態頁，待確認時每 30 秒更新
│  └─ admin.js                ［新增］員工後台
├─ css/booking.css            ［新增］沿用 styles.css 的變數
├─ admin/index.html           ［新增］員工後台（登入後才有資料；加 noindex）
├─ vendor/supabase.js         ［新增］supabase-js 固定版本，只有後台載入
├─ language.js                ［沿用］新頁面也引入；動態文字另用 I18N 字典
├─ supabase/
│  ├─ migrations/0001_booking_core.sql   ［已完成、已測試］
│  ├─ migrations/0002_cron.sql           ［已完成、未在實際 Supabase 測試］
│  ├─ seed.sql                           ［已完成］房型、區塊、預設設定
│  ├─ tests/                             ［已完成］52 項檢查
│  └─ functions/
│     ├─ create-booking/index.ts         ［待實作］驗證 Turnstile → 呼叫 create_booking
│     ├─ on-booking-event/index.ts       ［待實作］寄信＋LINE 通知
│     ├─ ical/index.ts                   ［待實作］匯出給 Airbnb 等平台
│     └─ ical-sync/index.ts              ［待實作］匯入外部平台日曆
├─ docs/booking-architecture.md          ［本文件］
└─ .github/workflows/
   ├─ static.yml              ［修改］只發佈網站檔案（見 10.1）
   └─ supabase.yml            ［新增］自動部署資料庫與函式（見 10.2）
```

客人端只需要 `fetch`：Supabase 的資料庫函式本來就是 HTTP 端點（`/rest/v1/rpc/<函式名>`），所以不必在網站引入第三方 SDK，符合目前 README「無第三方腳本」的原則。只有員工後台為了登入與即時同步才載入 supabase-js，並建議把固定版本檔放進 `vendor/`，不依賴外部 CDN。

## 6. 客人端流程

1. **選房型**：房型卡片資料來自 `room_types`。從 `index.html` 帶 `?room=` 進來時預選。
2. **選日期**：載入時呼叫 `get_availability(今天, 今天+120天)`，畫出月曆，滿房日期灰掉，有價格時顯示每晚價格。先點入住日、再點退房日；範圍內有任何不可訂的夜晚就不允許。
3. **試算**：選定範圍後呼叫 `quote_stay`，顯示晚數、總額、訂金；若沒設價格則顯示「洽詢報價」。
4. **填資料**：人數（受房型上下限限制）、姓名、電話、Email、備註、個資同意勾選、Turnstile 驗證。
5. **送出**：`POST /functions/v1/create-booking`。成功 → 轉到 `booking-status.html?ref=…&t=<token>`；若回 `unavailable`（剛好被別人訂走）→ 留在頁面並重新載入日曆，提示改選。
6. **狀態頁**：用 `get_booking(ref, token)` 取資料。`pending` 時顯示「申請已送出」畫面並定時更新；員工確認後自動切換為「訂房已確認」畫面。
7. 日曆在分頁重新取得焦點時、以及每 60 秒重新抓一次，讓客人看到的接近即時。最終以送出時的資料庫檢查為準。

雙語：`booking.html` 沿用 `data-en` / `data-zh` 與 `language.js`（頁首需要有 `#language-toggle`，否則該腳本會出錯）。JS 產生的動態文字放進 `I18N = { zh: {...}, en: {...} }`，並用 `MutationObserver` 監聽 `<html lang>` 變化重繪。

## 7. 員工後台（`/admin/`）

- **登入**：Supabase Auth 的 Email 一次性連結／驗證碼。登入後再查 `staff` 白名單，不在名單內只會看到「無權限」，資料庫本身也不會回傳任何訂單。
- **時間軸視圖**：列＝6 個區塊（A1…B3），欄＝日期（一次 30 天）。色塊：待確認（琥珀）、已確認（青綠）、關房（灰）、外部平台（藍灰）。
- **操作**：
  - 拖選空白日期 → 「新增訂單」（電話／LINE 客人，呼叫 `staff_create_booking`）或「關房」（`staff_block`）。
  - 點色塊 → 側欄顯示客人資料，按鈕：**確認並記錄收到訂金**、取消、編輯備註與金額、重寄確認信。
  - 「待處理」清單：所有 `pending` 依到期時間排序，快逾時的標紅。
- **即時同步**：訂閱 `bookings`、`booking_zones` 的變更，多位員工同時開著時，一人改動，其他人畫面立刻更新；客人新送出的申請也會立刻出現。
- **價格設定**：選房型與日期範圍，批次寫入 `daily_prices`（平日／假日各設一個價）。
- 修改日期請「取消後重建」；直接改日期若與其他訂單衝突，資料庫會拒絕。

## 8. Edge Functions（待實作）

| 函式 | 觸發 | 做什麼 |
|---|---|---|
| `create-booking` | 客人送出 | 驗證 Turnstile → 以 service role 呼叫 `create_booking` → 回傳結果。`create_booking` 對 anon 已被撤銷，瀏覽器無法繞過機器人驗證直接呼叫 |
| `on-booking-event` | 資料庫 Webhook（`bookings` 新增／狀態變更） | 新申請：寄「申請已收到」給客人、通知員工；轉 `confirmed`：寄確認信（即我們設計的 Email）；`cancelled`：寄取消通知。以共用密鑰驗證來源 |
| `ical` | Airbnb 等平台定時抓取 | 輸出指定房源占用的日期 |
| `ical-sync` | 排程（每 15–30 分鐘） | 抓外部平台日曆，寫入 `blocked` 訂單（`source='airbnb'`，以 UID 去重） |

通知渠道：Email 建議用 Resend 之類服務，寄件網域設為 `baisha36.co`，並設定 SPF/DKIM。員工 LINE 通知請用 **LINE Messaging API**（LINE Notify 已於 2025 年停止服務）。

`create-booking` 骨架（示意，尚未測試）：

```ts
Deno.serve(async (req) => {
  const b = await req.json();
  const v = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
    method: 'POST',
    body: new URLSearchParams({ secret: Deno.env.get('TURNSTILE_SECRET')!, response: b.turnstile }),
  }).then(r => r.json());
  if (!v.success) return json({ ok: false, error: 'bot_check_failed' }, 400);

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data } = await sb.rpc('create_booking', {
    p_room_type: b.room, p_in: b.check_in, p_out: b.check_out, p_guests: b.guests,
    p_name: b.name, p_phone: b.phone, p_email: b.email, p_note: b.note, p_lang: b.lang,
  });
  return json(data);   // CORS 只允許 baisha36.co 與 GitHub Pages 網域
});
```

## 9. 與外部平台（Airbnb 等）同步

- **匯出**：每個外部房源對應一組區塊，產生 `.ics` 網址貼到平台。
- **匯入**：定時抓取，轉成 `blocked` 訂單占用同一組區塊。
- **限制**：iCal 同步不是即時的，平台更新通常有數小時延遲，存在小機率的重複訂房空窗。若在外部平台也上架，建議只開放部分房型，或在外部平台訂單進來時由員工人工複核。此部分需要新增一張 `channel_listings` 表（`0003` migration，尚未寫）。

## 10. 部署

### 10.1 調整 `static.yml`（避免把 `supabase/`、`docs/` 發佈到公開網站）

目前 workflow 以 `path: '.'` 上傳整個 repo。改成先組裝網站目錄：

```yaml
      - name: Assemble site
        run: |
          mkdir _site
          rsync -a --exclude '.git' --exclude '.github' --exclude 'supabase' \
                --exclude 'docs' --exclude 'README.md' --exclude '_site' ./ _site/
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: '_site'
```

### 10.2 新增 `.github/workflows/supabase.yml`（資料庫與函式自動部署）

```yaml
name: Deploy Supabase
on:
  push:
    branches: [main]
    paths: ['supabase/**']
  workflow_dispatch:
jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
      SUPABASE_DB_PASSWORD: ${{ secrets.SUPABASE_DB_PASSWORD }}
    steps:
      - uses: actions/checkout@v4
      - uses: supabase/setup-cli@v1
      - run: supabase link --project-ref ${{ secrets.SUPABASE_PROJECT_REF }}
      - run: supabase db push
      - run: supabase functions deploy
```

指令與 action 名稱請對照 Supabase 官方文件確認（我沒有在這個環境實際執行）。請等專案建好、確認 migration 無誤後再啟用；它會直接修改正式資料庫。

### 10.3 機密放哪裡

| 值 | 放哪 | 可否進 repo |
|---|---|---|
| Supabase URL、anon key、Turnstile site key | `config.js` | 可以（設計上就是公開值，安全性來自 RLS） |
| service role key、Turnstile secret、Resend key、LINE token | Supabase Edge Function secrets | **絕對不行** |
| Supabase access token、DB 密碼 | GitHub repo secrets | **絕對不行** |

## 11. 上線順序（建議）

1. **Phase 0：建立專案**：建立 Supabase 專案（區域選離台灣近的），套用 migration 與 seed，建立 2 位員工帳號並寫入 `staff`。補上 `room_types` 的房價、訂金比例、最少晚數。
2. **Phase 1：員工後台先上線**：`admin/` 完成後，電話與 LINE 的訂單改為在後台登記。風險最低，立刻有用，也能先驗證房況假設是否正確。
3. **Phase 2：客人端唯讀日曆**：在網站公開空房日曆，下單仍走 LINE／電話。
4. **Phase 3：線上送出申請**：`create-booking`、狀態頁、通知信、Turnstile，員工收到訂金後在後台按確認。
5. **Phase 4：進階**：外部平台 iCal 同步；線上刷卡（台灣常見金流如綠界，需另評估費率與申請流程）；加購項目（兒童床等）。

## 12. 安全與個資

- 所有資料表開啟 RLS。匿名使用者讀不到任何訂單（已測試）；登入但不在 `staff` 名單的人也讀不到、改不了（已測試）。
- 狀態頁需要訂單編號＋隨機 token 才能查詢，避免他人猜編號看到別人資料。
- `create_booking` 只有 Edge Function 能呼叫；單一 Email 或電話最多同時 3 筆待確認，防止惡意占住日期（已測試）。
- 訂房表單需有個資蒐集告知與同意勾選，並決定保存期限與刪除方式（台灣個資法相關義務請以專業意見為準）。
- 建議為員工帳號啟用 MFA；`admin/` 加上 `noindex`。
- 備份與專案暫停規則依 Supabase 方案而異，正式營運前請查官方方案說明，必要時用 GitHub Actions 定期匯出備份。

## 13. 測試

已完成（`supabase/tests/booking_core_test.sql`，52 項全數通過）：

- 配房：海景樓中樓 → A 棟 2F＋3F；泳池雙房優先放進較忙的 A 棟；Villa 包棟放入 B 棟。
- 衝突：兩棟都占用時所有房型皆滿房；全館包棟占滿六個區塊，其他房型同晚不可訂，退房當天可訂。
- 同日換房可以；第三組 Villa 包棟被拒絕（只有兩棟）。
- 取消後立刻釋出；過期保留自動釋出；直接塞入重疊資料被 EXCLUDE 約束擋下。
- 驗證：電話、Email、人數、過去日期、退房早於入住、超過 30 晚、未知房型、同一 Email 第 4 筆待確認。
- 價格：逐日覆蓋價、訂金 30% 試算、未設價格時回傳 null。
- 權限：匿名、一般登入者、員工、service role 各自能做與不能做的事。
- 同時搶訂：8 人同時搶全館只成功 1 人；5 人同時搶 Villa 包棟只成功 2 人。

**尚未驗證**：在真正的 Supabase 專案上執行（本機測試是用純 PostgreSQL 16 加上模擬的 `auth` 結構）、`pg_cron`、Realtime 發佈、所有前端頁面與 Edge Functions。

## 14. 已知取捨

- 日曆上每一天的「可訂」是「從這天起住一晚」的判斷；跨多晚是否可訂以 `quote_stay` 為準。
- 待確認訂單在保留期內會占住日期；若員工太慢確認，會影響其他客人。保留時數請依實際作業調整。
- 目前沒有逐間臥室的庫存（以樓層區塊為單位）。若日後想把單一臥室分開賣，需要把區塊拆得更細並調整房型對應。
- 加購（兒童床、烤肉）、取消政策與退款規則尚未建模。
