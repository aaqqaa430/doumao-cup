# 豆猫杯 · 沉沦者的黑流树海

> 一个**同人赛事站点**：单文件静态前端 + 一个云函数 + 一套 PostgreSQL 函数，
> 没有构建步骤，没有框架。赛事主题取自《明日方舟》的「集成战略」模式。
> 代码本身与任何组织、学校、公司无关，就是一个爱好者赛事网页的实现。

<p>
  <img alt="license" src="https://img.shields.io/badge/license-Apache--2.0-blue">
  <img alt="frontend" src="https://img.shields.io/badge/frontend-vanilla%20JS%20%C2%B7%20no%20build-yellowgreen">
  <img alt="backend" src="https://img.shields.io/badge/backend-CloudBase%20PG%20%2B%20HTTP%20Function-orange">
</p>

[English summary ↓](#english-summary)

---

## 这是什么

一个给小型同人赛事用的展示站，几个模块拼在一起：

| 模块 | 说明 |
| --- | --- |
| **选手风云殿** | 选手卡片墙，按分队 / 难度筛选，支持全站即时搜索与应援排行 |
| **应援系统** | 每人每天 N 次应援额度，服务端裁定，前端绕不过；额度可由小游戏赢取 |
| **黑流搏浪** | 一个 Canvas 打捞小游戏，难度曲线对齐了原作；成绩可留名上排行榜 |
| **规程切片** | 把超长规则长图切段后分段懒加载，带双阅读模式与手势翻页 |
| **命运占卜** | 藏品单抽，6 档吉凶各有独立特效 |
| **当前总台** | 吸顶直播条，服务端实时拉 B 站开播状态，管理台可自助改 |
| **管理台** | 密钥门禁 → 两个页签（总台配置 / 选手标签），见下方安全说明 |

## 这**不是**什么

写清楚比写好看重要：

- **不是**通用赛事平台。选手名单、分队名、规则文案都写死在页面里，换赛事要改代码。
- **不是**有账号体系的系统。没有注册、没有登录、没有用户表——只有匿名设备标识。
- **不是**能防刷票的系统。见[已知限制](#已知限制)。
- **不包含**任何美术素材，也**不包含游戏内文本**。仓库里没有图，只有引用图片的路径；藏品的名称、效果、说明已全部替换成原创占位文本。见 [`web/assets/README.md`](web/assets/README.md)。

---

## 架构

```
              浏览器（静态页 · 无构建）
   ┌──────────────────────────────────────────────────┐
   │  index.html    选手墙 / 应援 / 小游戏 / 占卜      │
   │  admin.html    密钥门禁 → 总台页签 + 标签页签     │
   │  live-admin.html / tag-admin.html                 │
   │                （旧地址，仅 302 到 admin.html）   │
   └───────────────────────┬──────────────────────────┘
                           │  只有这一条通道
                           ▼
        ┌──────────────────────────────────────────┐
        │  CloudBase HTTP 云函数  server/index.js   │
        │  · 校验 / 清洗 / 限流 / 参数化路由        │
        │  · 管理密钥只在这里，永不下发             │
        │  · 代前端拉 B 站状态（绕开 CORS）         │
        └───────────────────┬──────────────────────┘
                            │  PostgREST /rpc/<fn>
                            ▼
        ┌──────────────────────────────────────────┐
        │  PostgreSQL（SQL 见 sql/）                │
        │  全部写操作走 SECURITY DEFINER 函数       │
        │  含 device_id 的表对 anon 完全不授权      │
        └──────────────────────────────────────────┘
```

三个设计决定贯穿全站：

1. **前端零密钥。** 静态页里没有任何凭据。管理密钥只存在于服务端。
2. **写操作不可绕过。** 额度、局次校验、分数夹紧全在 SQL 函数里，改前端没用。
3. **能匿名就匿名。** 不采 IP、不采指纹，`device_id` 是浏览器本地随机生成的串。

细节见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

---

## 快速开始

### 只看看长什么样（30 秒）

仓库里没图，藏品文案也是占位文本，但所有交互都能跑：

```bash
cd web && python -m http.server 8080
# 打开 http://127.0.0.1:8080/index.html
```

页面会尝试连云函数——地址还是占位符，所以它会安静地降级到内置离线数据。这是预期行为。

### 完整部署（需要腾讯云账号）

四步，每步的命令都在 [`docs/DEPLOY.md`](docs/DEPLOY.md)：

1. 建 CloudBase 环境 + PostgreSQL
2. 按序号执行 `sql/01` → `sql/06`（全部幂等）
3. 复制 `server/.env.example` 为 `.env`，填环境 ID 和 API Key，部署云函数
4. 把 `web/` 传到任意静态托管（COS / Vercel / Netlify / GitHub Pages 都行）

**上线前务必改这两处**，否则站点会连不上或指向错误的地方：

- `web/index.html` 与 `web/admin.html` 里的 `CHEER_API` / `API` 常量
- `sql/04_live_studio.sql` 里那把 `CHANGE-ME-...` 管理口令

---

## 目录结构

```
.
├── web/                     静态前端（无构建，直接部署）
│   ├── index.html           单文件主站，全部逻辑内联
│   ├── admin.html           管理台（门禁 + 双页签）
│   ├── live-admin.html      旧地址 → admin.html#live
│   ├── tag-admin.html       旧地址 → admin.html#tags
│   └── assets/
│       ├── README.md        需要你自己准备的图片清单
│       └── data/            选手 / 藏品 / 规程切片的数据契约（均为占位数据）
├── server/
│   ├── index.js             CloudBase HTTP 云函数（唯一后端入口）
│   ├── scf_bootstrap        启动脚本（9000 端口）
│   └── .env.example
├── sql/                     六个幂等迁移，按序号执行
│   ├── 01_game_and_cheer.sql    额度表 / 局次令牌 / 应援计数
│   ├── 02_leaderboard.sql       排行榜 + 昵称清洗
│   ├── 03_layer_rewards.sql     兑奖档位：层数 → 票数
│   ├── 04_live_studio.sql       当前总台配置 + 管理密钥
│   ├── 05_player_tags.sql       选手标签
│   └── 06_admin_gate.sql        管理台只读验钥
└── docs/
    ├── ARCHITECTURE.md
    ├── DEPLOY.md
    └── DECLARATION-TEMPLATE.md  开源公告草稿
```

---

## 已知限制

诚实列一下，免得别人以为这是个能扛住压力的系统：

| 限制 | 说明 |
| --- | --- |
| **票数可以被刷** | 投票只要求一个自造的 `device_id`。脚本每次换随机设备号即可绕过每日额度。**票数只应视为示意性人气，不能作为名次的严肃依据。** |
| **无账号体系** | 换浏览器 / 清缓存 = 新身份，额度跟着重置。这是匿名换来的代价。 |
| **单实例内存限流** | 管理密钥试错限流是进程内计数，多实例部署时会各算各的。想做严格限流请挪到 Redis 或数据库。 |
| **选手名单硬编码** | 前端和 `players.json` 各有一份，靠一条静态断言保证 id 顺序一致。改赛事要同时改。 |

缓解思路见 [`SECURITY.md`](SECURITY.md#已知薄弱点与缓解方向)。

---

## 安全与隐私

- 安全模型、威胁分析与已知薄弱点 → [`SECURITY.md`](SECURITY.md)
- 收集了什么、没收集什么 → [`PRIVACY.md`](PRIVACY.md)
- 同人作品免责声明与素材版权归属 → [`DISCLAIMER.md`](DISCLAIMER.md)

发现漏洞请按 `SECURITY.md` 里的方式私下告知，**不要直接开公开 issue**。

---

## 许可

- **代码**：Apache License 2.0，见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。
- **《明日方舟》游戏美术素材**：版权归鹰角网络所有，**本仓库不包含、也不授权分发**。详见 [`DISCLAIMER.md`](DISCLAIMER.md)。
- **游戏内文本**（藏品名称、效果、说明等）：同为游戏内容，**本仓库不包含**——这些字段已全部替换成原创占位文本。
- **选手名单**：本仓库中的名单已替换为占位数据，不含任何真实个人信息。

---

## 致谢

- 《明日方舟》与集成战略「沉沦者的黑流树海」—— 鹰角网络
- 设计语言参考了原作的实机色彩规范与藏品卡面构图
- 腾讯云 CloudBase 提供环境、数据库与函数计算

本项目是非商业同人作品，与鹰角网络及 B 站无隶属关系。

---

<a id="english-summary"></a>

## English summary

A static **fan-site** for a small *Arknights* Integrated Strategies tournament
(*Doumao Cup · Blackstream Tree Sea*). No framework, no build step:
one self-contained `index.html`, one HTTP cloud function, and a set of
PostgreSQL functions.

**Design invariants**

- **Zero secrets in the frontend.** The admin key exists only server-side.
- **Writes cannot be forged from the client.** Quotas, session validation and
  score clamping all live in `SECURITY DEFINER` SQL functions behind
  parameterised `PostgREST` calls.
- **Privacy by omission.** No IP addresses, no fingerprints. The per-browser
  `device_id` is a locally generated random string used only for daily quotas.

**Honest caveats** — votes can be stuffed by scripting random device IDs, so
counts are indicative only. See [`SECURITY.md`](SECURITY.md) for the full
threat model.

Repo contents: `web/` (frontend), `server/` (cloud function), `sql/` (six
idempotent migrations), `docs/`.

**No game art or in-game text is included.** Both are © Hypergryph and are out
of scope for this licence; every placeholder string in the repo is original.
See [`DISCLAIMER.md`](DISCLAIMER.md).

Code is licensed under Apache-2.0.
