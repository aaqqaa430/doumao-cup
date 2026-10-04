# 部署指南

从零到线上，大约 30 分钟。全程只需要一个腾讯云账号。

> **只想看看样子？** 不用往下看。`cd web && python -m http.server 8080` 就够了，
> 页面会自动降级到内置的离线数据。

---

## 总览

```
① 建 CloudBase 环境（含 PostgreSQL）
        ↓
② 执行 sql/01 → sql/06                ← 建表 + 建函数 + 写初始口令
        ↓
③ 建一枚 API Key                       ← 云函数用它连数据库
        ↓
④ 部署 server/ 为 HTTP 云函数           ← 填两个环境变量
        ↓
⑤ 改前端里的接口地址，把 web/ 传上去     ← 静态托管随便挑
```

每一步的具体界面以控制台实际为准——云产品的控制台改版很勤，
下面给的是**要找什么**而不是"点第几个按钮"。

---

## ① 建环境

腾讯云控制台 → **云开发 CloudBase** → 新建环境。

- 记下 **环境 ID**，形如 `your-env-1234abcd`。后面处处要用。
- 地域选择：就近。原项目用的是 `ap-shanghai`。
- 在环境里开通 **PostgreSQL**（不是文档数据库）。

开通后，在数据库页面找到**连接串**（通常形如
`postgresql://user:pass@host:5432/dbname`）。后面的步骤要用。

---

## ② 建库

用任意 PostgreSQL 客户端连上去（`psql`、DBeaver、pgAdmin 都行），
**按文件名顺序**执行 `sql/` 下的六个文件：

```bash
psql "postgresql://user:pass@host:5432/dbname" -f sql/01_game_and_cheer.sql
psql "postgresql://user:pass@host:5432/dbname" -f sql/02_leaderboard.sql
psql "postgresql://user:pass@host:5432/dbname" -f sql/03_layer_rewards.sql
psql "postgresql://user:pass@host:5432/dbname" -f sql/04_live_studio.sql
psql "postgresql://user:pass@host:5432/dbname" -f sql/05_player_tags.sql
psql "postgresql://user:pass@host:5432/dbname" -f sql/06_admin_gate.sql
```

### ⚠️ 执行前先改一处

打开 `sql/04_live_studio.sql`，找到：

```sql
INSERT INTO public.site_secret (name, value)
VALUES ('live_admin_key', 'CHANGE-ME-to-a-long-random-string')
```

**把 `CHANGE-ME-...` 换成你自己的口令。** 这是进管理台的钥匙，也是唯一能改总台配置
和选手标签的凭据。

生成一把够长的：

```bash
openssl rand -base64 24
# 或者任意密码管理器生成 28 位以上随机串
```

改完再执行 04，否则你会带着一个公开的示例口令上线。

### 关于这六个文件

全部语句都是幂等的（`CREATE ... IF NOT EXISTS` / `CREATE OR REPLACE`），
**可以放心重复执行**。它们是从生产环境的真实迁移脚本导出的，按原顺序排列——
后面的文件会替换前面定义的同名函数，这是正常的，按顺序跑完就是正确的最终状态。

每个文件末尾的 `NOTIFY pgrst, 'reload schema'` 是让 PostgREST 网关重新加载函数索引，
**别删**，否则新函数在 API 上不生效。

---

## ③ 建 API Key

云函数需要一枚能读写数据库的凭据。

控制台 → 环境 → **API Key / 访问密钥** → 新建。

- 权限：只给这个环境所需的数据库读写权限，**不要用账号根密钥**。
- 记下这串 Key（很长，通常是个 JWT）。

> **这枚 Key 的暴露后果 = 你的数据库直接被人读走。**
> 它只应该出现在云函数的环境变量里，永远不要写进前端、不要提交到 git。
> 仓库里的 `.gitignore` 已经覆盖了常见文件名，但真正的保障是你别复制粘贴错地方。

---

## ④ 部署云函数

### 准备

`server/` 目录里有两个文件：

| 文件 | 说明 |
| --- | --- |
| `index.js` | 全部逻辑，约 630 行，**零依赖** |
| `scf_bootstrap` | 启动脚本：`#!/bin/bash` + `node index.js` |

`scf_bootstrap` 有三个必须保住的性质，否则函数起不来：

- **没有扩展名**（就叫 `scf_bootstrap`）
- **LF 换行**，不是 CRLF
- **可执行权限 0755**

```bash
# 检查一下（应该输出 "#!/bin/bash$" 和 "node index.js$"，行尾的 $ 表示 LF）
cat -A server/scf_bootstrap
chmod 755 server/scf_bootstrap
```

### 环境变量

在云函数配置里加两个：

| 变量 | 值 |
| --- | --- |
| `CHEER_ENV_ID` | 你在 ① 记下的环境 ID |
| `CHEER_API_KEY` | 你在 ③ 拿到的 Key |

`server/.env.example` 是模板。**不要**把真实的 `.env` 提交进版本库。

### 部署方式 A：控制台上传

把 `server/` 下的两个文件打成一个 zip（**注意别把它们放进子目录**，
解压后必须直接是 `index.js` 和 `scf_bootstrap`），
然后在 CloudBase 控制台新建 **Web 函数 / HTTP 函数**，选择"上传代码包"。

- 函数名随意（原项目叫 `cheer`）。
- 运行环境：Node.js 18 或更高。
- 安装依赖：**不需要**（没有依赖）。

### 部署方式 B：命令行

```bash
cd server
zip -r ../fn.zip index.js scf_bootstrap   # -r 保证带上 scf_bootstrap
```

然后用你的云厂商 CLI 上传。腾讯云可以用 `tcb` CLI，或者用
`UpdateFunctionCode` API（注意它要的是 **base64 编码后的 zip**，
不能直接传二进制）。

### 关键：监听 9000 端口

CloudBase 的 Web 函数要求进程监听 **9000** 端口，从 `0.0.0.0` 绑定。
`index.js` 里已经写好了：

```js
const PORT = 9000;
server.listen(PORT, '0.0.0.0', ...);
```

### 部署后先烟测

**部署完不要立刻做完整测试**——云函数的实例有预热过程，
刚部署完的几十秒内请求可能还打到旧实例上，症状是"有些断言莫名失败，单独重跑又过"。

先只打一条最简单的：

```bash
API="https://<你的环境ID>-<appid>.<地域>.app.tcloudbase.com/cheer"
curl -s "$API?leaderboard=1&limit=1"
# 期望：{"ok":true,...}  而不是 500
```

拿到 `ok:true` 再往下走。

---

## ⑤ 前端

### 改接口地址

页面里写死了一处接口地址（原仓库是占位符 `https://YOUR_ENV_ID-...`），
**必须换成你自己的**：

| 文件 | 位置 |
| --- | --- |
| `web/index.html` | 搜 `const CHEER_API =` |
| `web/admin.html` | 搜 `var API =` |

地址就是上一步烟测用的那个。

### 改选手名单

名单有**三份**，改的时候要一起改，**id 顺序必须逐位一致**
（数据是按 id 关联的，错位会静默张冠李戴）：

1. `web/index.html` → 搜 `const PLAYERS_DATA =`
2. `web/admin.html` → 搜 `var ROSTER =`
3. `web/assets/data/players.json`

原项目靠一条静态断言保住这个不变量，建议你也留一条。

### 改藏品数据

占卜池在**两处**，内容要一致：

1. `web/index.html` → 搜 `const RELICS_DATA =`（48 件，`tier` 是吉凶档，`effect` / `desc` 是卡片上的「作用」「说明」）
2. `web/assets/data/relics.json`（数据契约，供外部工具读取）

仓库里藏品的**名称、效果、说明全是占位文本**（`藏品01`…`藏品48`）。
换成你自己的内容即可 —— 但**别直接从游戏图鉴里抄**，那些文案是鹰角的版权内容，
正是原项目把它们全部换掉的原因。

### 配置当前总台

仓库里的房间号是**空的**，所以首页那条吸顶直播条默认整条收起（不占位置）。
两种填法：

- 打开 `web/admin.html`，用管理密钥进去，在「当前总台」页签里填房间号并保存；
- 或者直接执行 SQL：`SELECT public.live_set('<你的密钥>', '<房间号>', '<标题>', '<备注>', true);`

填好之后刷新首页，直播条就会出现，并显示实时开播状态。

### 准备图片

仓库里没有图。需要哪些文件见 [`../web/assets/README.md`](../web/assets/README.md)。

### 传上去

`web/` 是纯静态文件，**任何静态托管都能放**：

| 托管 | 说明 |
| --- | --- |
| 腾讯云 COS | 原项目用的这个。需要配静态网站 + 自定义域名 + HTTPS 证书 |
| Vercel / Netlify | 拖进去就行，自带 HTTPS 和 CDN |
| GitHub Pages | 免费，但国内访问可能不稳 |
| Cloudflare Pages | 免费，自带 CDN |

> 注意：**必须用 `https://` 打开页面。**
> 用 `file://` 直接双击打开的话，页面发往 `https://` 的跨域请求会被浏览器拦下，
> 应援和排行榜都会显示"尚未连接服务器"。

---

## ⑥ 上线前检查

逐条打勾再发出去：

- [ ] `sql/04` 里的管理口令已经换成自己的（不是 `CHANGE-ME-...`）
- [ ] `web/index.html` 和 `web/admin.html` 的接口地址已改成自己的
- [ ] 三份选手名单已同步，id 顺序一致
- [ ] 藏品数据已换成自己的（**没有直接抄游戏图鉴的文案**）
- [ ] 当前总台的房间号已配置（否则首页直播条一直是收起的）
- [ ] 云函数的环境变量已配置，且 **`.env` 没有提交进 git**
- [ ] API Key 用的是最小权限 Key，不是账号根密钥
- [ ] 生产库里的 API Key 没有出现在任何前端文件里（`grep -rn "你的Key前缀" web/`）
- [ ] 首页能开、选手墙有数据
- [ ] 应援一次，票数 +1，刷新后不回落
- [ ] 玩一局小游戏，额度确实增加了
- [ ] 输入昵称提交成绩，排行榜出现该条
- [ ] 打开 `admin.html`：错钥被拦、对钥能进、两个页签都读到了真实数据
- [ ] 隐私声明已按实际配置更新（尤其云平台日志、有没有加 IP 限流）
- [ ] 页面上已注明**票数是示意性人气，不是严肃计票**（见 `SECURITY.md`）

---

## 常见问题

**函数部署后立刻测失败，重试又好**
云函数实例预热。等 30 秒，或者先只打一条最简单的请求确认新版本生效。

**页面显示"尚未连接服务器"**
八成是接口地址没改，或者你用了 `file://` 打开。用 `https://` 或 `localhost` 访问。

**管理台登录一直说密钥不对**
① `sql/04_live_studio.sql` 里的口令到底有没有执行成功？连上去查一下：

```sql
SELECT name, left(value, 8) || '…' FROM public.site_secret;
```

② 试错限流触发了吗？5 分钟内失败 30 次会锁。等 5 分钟。

**标签改了但首页没变**
首页有缓存逻辑，刷新一下。还不行就确认 `tag_admin_key` 有没有写进 `site_secret`
（`sql/05` 会复用 `sql/04` 写的那把）。

**换云厂商要改什么**
只改 `server/index.js` 里的 `restCall()`。它现在打的是 CloudBase 的 PostgREST 网关
（`https://<env>.api.tcloudbasegateway.com/v1/rdb/rest`），换成 `pg` 客户端直连即可，
业务逻辑一行都不用动。
