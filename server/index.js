/**
 * 豆猫杯 · 应援同步接口（CloudBase HTTP 云函数 / Web 函数）
 *
 * 形态要求：必须作为 Web Server 监听 9000 端口，由 scf_bootstrap 拉起。
 * 职责：浏览器与 PostgreSQL 之间的唯一通道，管理密钥只存在于服务端环境变量。
 *
 *   GET  /?deviceId=xxx                      → 全部选手票数 + 该设备今日额度（含打捞奖励）
 *   GET  /?deviceId=xxx&vote=<playerId>      → 投一票（供 <img> 信标兜底，QQ/微信内置浏览器用）
 *   POST /  {deviceId, playerId}             → 投一票（主通道）
 *
 *   GET  /?deviceId=xxx&gameStart=1          → 开局，取本局令牌（打捞小游戏用）
 *   POST /  {deviceId, score, token, nickname, layer, relics, combo}
 *                                            → 结算打捞成绩，领取额外应援额度
 *   GET  /?deviceId=xxx&score=N&token=T&nickname=xxx
 *                                            → 同上，供信标 / JSONP 兜底通道
 *   GET  /?leaderboard=1&limit=20            → 打捞排行榜（公开只读，不需要 deviceId）
 *
 *   GET  /?live=1                            → 当前总台直播间：库里的配置 + B 站实时开播状态
 *   GET  /?liveSet=1&key=K&room=R&title=T&note=N&enabled=1
 *   POST /  {liveSet:true, key, room, title, note, enabled}
 *                                            → 更新当前总台（凭管理口令，口令只在服务端比对）
 *
 *   GET  /?tags=1                            → 全部选手标签 { "1": ["完赛"], ... }（公开只读）
 *   GET  /?tagSet=1&key=K&playerId=1&tags=完赛|四星干员
 *   POST /  {tagSet:true, key, playerId, tags:["完赛"]}
 *                                            → 覆盖某位选手的全部标签（凭管理口令，整组替换）
 *
 *   nickname 为空则不写入排行榜，但奖励照发。
 *   四个写通道共用同一套服务端限流与局次校验，前端绕不过。
 *   每日额度 = BASE_LIMIT(50) + 打捞奖励(0~50)，打捞奖励存于 cheer_bonus。
 *   支持 &callback=fn 返回 JSONP（内置浏览器拦截跨域请求时的兜底通道）。
 */
const http = require('http');
const https = require('https');

const ENV_ID = process.env.CHEER_ENV_ID || '';
const API_KEY = process.env.CHEER_API_KEY || '';
const BASE_LIMIT = 50;
const MAX_BONUS = 50;
const PLAYER_MIN = 1;
const PLAYER_MAX = 21;
const NICK_MAX = 16;
const BOARD_MIN = 1;
const BOARD_MAX = 50;
const TAG_MAX = 12;      // 单个标签最多 12 字（按码点，服务端 SQL 里再卡一次）
const TAG_COUNT_MAX = 6; // 每位选手最多 6 个标签
const PORT = 9000;
const REST_BASE = 'https://' + ENV_ID + '.api.tcloudbasegateway.com/v1/rdb/rest';
const DEVICE_RE = /^[A-Za-z0-9_-]{8,64}$/;
const TOKEN_RE = /^[a-f0-9]{32,64}$/;
const CTRL_RE = /[\u0000-\u001f\u007f]/g;

/** 昵称清洗：去控制字符 → 压缩空白 → 去首尾 → 截断 NICK_MAX 字（按码点，不劈开代理对）。 */
function cleanNick(raw) {
  if (raw === undefined || raw === null) return '';
  return Array.from(String(raw).replace(CTRL_RE, '').replace(/\s+/g, ' ').trim())
    .slice(0, NICK_MAX)
    .join('');
}

/** 取非负整数，非法时返回 def。 */
function toInt(raw, def) {
  if (raw === undefined || raw === null || String(raw) === '') return def;
  var n = parseInt(raw, 10);
  return isNaN(n) ? def : n;
}

function restCall(path, method, body) {
  return new Promise(function (resolve, reject) {
    var u = new URL(REST_BASE + path);
    var payload = body ? JSON.stringify(body) : null;
    var headers = {
      Authorization: 'Bearer ' + API_KEY,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    };
    if (payload) headers['Content-Length'] = Buffer.byteLength(payload);

    var req = https.request(
      {
        hostname: u.hostname,
        port: 443,
        path: u.pathname + u.search,
        method: method || 'GET',
        headers: headers,
        timeout: 8000,
      },
      function (res) {
        var chunks = [];
        res.on('data', function (c) {
          chunks.push(c);
        });
        res.on('end', function () {
          var text = Buffer.concat(chunks).toString('utf8');
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try {
              resolve(JSON.parse(text));
            } catch (e) {
              resolve(text);
            }
          } else {
            reject(new Error('REST ' + res.statusCode + ': ' + text.slice(0, 180)));
          }
        });
      }
    );
    req.on('timeout', function () {
      req.destroy(new Error('upstream timeout'));
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

/* --------------------------------------------------------------------------
   总台直播间：向 B 站拉实时开播状态
   —— 放在服务端做，前端只跟本函数打交道：不受 CORS 限制、不受内置浏览器影响，
      还能短缓存，避免每个访客都去打一次 B 站。
   -------------------------------------------------------------------------- */
var BILI_HOST = 'api.live.bilibili.com';
var BILI_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
var LIVE_CACHE_MS = 45000;
var ROOM_RE = /^[0-9]{1,12}$/;

var biliCache = { roomId: '', at: 0, data: null };

/** 拉一个 B 站接口；任何异常都解析成 null，绝不把上游故障透成 500。 */
function biliGet(path) {
  return new Promise(function (resolve) {
    var req;
    try {
      req = https.request(
        {
          hostname: BILI_HOST,
          port: 443,
          path: path,
          method: 'GET',
          headers: {
            'User-Agent': BILI_UA,
            Referer: 'https://live.bilibili.com/',
            Accept: 'application/json, text/plain, */*',
          },
          timeout: 5000,
        },
        function (res) {
          var chunks = [];
          res.on('data', function (c) {
            chunks.push(c);
          });
          res.on('end', function () {
            try {
              resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
            } catch (e) {
              resolve(null);
            }
          });
        }
      );
    } catch (e) {
      return resolve(null);
    }
    req.on('timeout', function () {
      req.destroy();
      resolve(null);
    });
    req.on('error', function () {
      resolve(null);
    });
    req.end();
  });
}

function clip(v, n) {
  var s = v === undefined || v === null ? '' : String(v);
  // 按码点截断，避免把 emoji / 代理对劈成半个字符
  var arr = Array.from(s);
  return arr.length > n ? arr.slice(0, n).join('') : s;
}

/**
 * 展示文本清洗：去控制字符 → 压缩空白 → 去首尾 → 按码点截断。
 * 必须在发给 PostgREST **之前**做 —— NUL(0x00) 这类字符 PostgreSQL 的 text 根本存不下，
 * 带进去会整个请求报错，库里的清洗函数再周全也轮不到它执行。
 */
function cleanStageText(raw, max) {
  if (raw === undefined || raw === null) return '';
  return clip(String(raw).replace(CTRL_RE, '').replace(/\s+/g, ' ').trim(), max);
}

/** 单个标签清洗：去控制字符 → 压空白 → 去首尾 → 截 TAG_MAX 字。空串由调用方丢弃。 */
function cleanTag(raw) {
  if (raw === undefined || raw === null) return '';
  return clip(String(raw).replace(CTRL_RE, '').replace(/\s+/g, ' ').trim(), TAG_MAX);
}

/**
 * 把标签参数归一成字符串数组：POST 发数组，GET 发 "完赛|四星干员" 这种串。
 * 去空、去重、限个数 —— 服务端 SQL 里还会再清一次，这里先把明显不合法的挡在外面。
 */
function parseTags(raw) {
  var list = [];
  if (Array.isArray(raw)) list = raw;
  else if (typeof raw === 'string') list = raw.split(/[|,、]/);
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var t = cleanTag(list[i]);
    if (!t) continue;
    if (out.indexOf(t) >= 0) continue;
    out.push(t);
    if (out.length >= TAG_COUNT_MAX) break;
  }
  return out;
}

/**
 * 取直播间概况。roomId 非法 / 上游不通 / 房间不存在都返回 null，
 * 让它回落到「只显示库里配置」的降级形态。
 */function fetchBili(roomId) {
  if (!ROOM_RE.test(roomId || '')) return Promise.resolve(null);

  var now = Date.now();
  if (biliCache.roomId === roomId && biliCache.data && now - biliCache.at < LIVE_CACHE_MS) {
    return Promise.resolve(biliCache.data);
  }

  return Promise.all([
    biliGet('/room/v1/Room/get_info?room_id=' + roomId),
    biliGet('/live_user/v1/UserInfo/get_anchor_in_room?roomid=' + roomId),
  ]).then(function (r) {
    var info = r[0] && r[0].data;
    // 房间不存在时 B 站会给 data:[]（空数组也是真值），必须挡掉，
    // 否则会渲染出一个「标题空、人气 0」的假直播间
    if (!info || typeof info !== 'object' || Array.isArray(info) || !info.room_id) return null;
    var anchor = (r[1] && r[1].data && r[1].data.info) || null;
    var st = parseInt(info.live_status, 10);
    if (isNaN(st)) st = 0;

    var out = {
      liveStatus: st, // 0 未开播 / 1 直播中 / 2 轮播
      isLive: st === 1,
      roomTitle: clip(info.title, 60),
      online: parseInt(info.online, 10) || 0,
      attention: parseInt(info.attention, 10) || 0,
      areaName: clip(info.area_name, 20),
      anchor: anchor ? clip(anchor.uname, 30) : '',
      face: anchor ? clip(anchor.face, 200) : '',
      liveTime: clip(info.live_time, 20),
      cover: clip(info.user_cover, 300),
    };
    biliCache = { roomId: roomId, at: Date.now(), data: out };
    return out;
  });
}

/** 管理口令试错限流：单实例内每 5 分钟最多错 30 次。
    阈值刻意放得比"防爆破"宽松 —— 口令是 24 位随机串，撞不出来；
    这一层只是为了压掉误填与噪声，不要让它变成正常使用的拦路石。 */
var KEY_WINDOW_MS = 5 * 60 * 1000;
var KEY_MAX_FAIL = 30;
var keyFails = [];

function keyLocked() {
  var now = Date.now();
  keyFails = keyFails.filter(function (t) {
    return now - t < KEY_WINDOW_MS;
  });
  return keyFails.length >= KEY_MAX_FAIL;
}

var CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Max-Age': '86400',
};

/**
 * 统一出口。cb 非空时按 JSONP 输出。
 * 显式覆盖 Content-Disposition —— QQ/微信内置浏览器看到 attachment 可能把响应
 * 交给下载器处理，导致 XHR 拿不到结果。
 */
function send(res, code, obj, cb) {
  var body = JSON.stringify(obj);
  var headers = Object.assign(
    {
      'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
      'Content-Disposition': 'inline',
      'X-Content-Type-Options': 'nosniff',
    },
    CORS_HEADERS
  );
  if (cb) {
    body = cb + '(' + body + ');';
    headers['Content-Type'] = 'application/javascript; charset=utf-8';
  } else {
    headers['Content-Type'] = 'application/json; charset=utf-8';
  }
  headers['Content-Length'] = Buffer.byteLength(body);
  res.writeHead(code, headers);
  res.end(body);
}

function snapshot() {
  return restCall('/cheer_counts?select=player_id,count&order=player_id.asc', 'GET');
}

/** 读取该设备今天已赢得的打捞奖励额度（0~50）。 */
function readBonus(deviceId) {
  return restCall('/rpc/game_bonus', 'POST', { p_device_id: deviceId }).then(function (v) {
    var n = parseInt(v, 10);
    if (isNaN(n) || n < 0) n = 0;
    return Math.min(n, MAX_BONUS);
  });
}

function readStatus(deviceId, limit) {
  return restCall('/rpc/cheer_status', 'POST', {
    p_device_id: deviceId,
    p_limit: limit,
  }).then(function (st) {
    if (st && typeof st === 'object') st.bonus = limit - BASE_LIMIT;
    return st;
  });
}

var server = http.createServer(function (req, res) {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return;
  }

  var u;
  try {
    u = new URL(req.url || '/', 'http://localhost');
  } catch (e) {
    return send(res, 400, { ok: false, reason: 'bad_url' });
  }

  // JSONP 回调名白名单，避免 XSS
  var cb = u.searchParams.get('callback') || '';
  if (cb && !/^[A-Za-z_$][A-Za-z0-9_$.]{0,63}$/.test(cb)) cb = '';

  var raw = '';
  req.on('data', function (c) {
    raw += c;
    if (raw.length > 4096) req.destroy();
  });

  req.on('end', async function () {
    var body = {};
    if (raw) {
      try {
        body = JSON.parse(raw);
      } catch (e) {
        return send(res, 400, { ok: false, reason: 'bad_json' }, cb);
      }
    }

    var deviceId = String(
      (body && body.deviceId) || u.searchParams.get('deviceId') || ''
    ).trim();

    var isPost = req.method === 'POST';

    // 排行榜 / 总台都是公开只读接口，不需要设备号
    var wantBoard =
      String(u.searchParams.get('leaderboard') || '') !== '' ||
      (body && body.leaderboard === true);

    // 当前总台：读
    var wantLive =
      String(u.searchParams.get('live') || '') !== '' || (body && body.live === true);

    // 当前总台：写（凭管理口令）
    var wantLiveSet =
      String(u.searchParams.get('liveSet') || '') !== '' || (body && body.liveSet === true);

    // 选手标签：读（公开只读）
    var wantTags =
      String(u.searchParams.get('tags') || '') !== '' || (body && body.tags === true);

    // 选手标签：写（凭管理口令，整组替换）
    var wantTagSet =
      String(u.searchParams.get('tagSet') || '') !== '' || (body && body.tagSet === true);

    // 管理口令：只读校验（管理台的门禁）。不写任何数据，只回 ok 布尔。
    var wantAuth =
      String(u.searchParams.get('auth') || '') !== '' || (body && body.auth === true);

    if (
      !wantBoard && !wantLive && !wantLiveSet && !wantTags && !wantTagSet && !wantAuth &&
      !DEVICE_RE.test(deviceId)
    ) {
      return send(res, 400, { ok: false, reason: 'bad_device' }, cb);
    }

    // 投票参数：POST body.playerId 为主通道，GET ?vote= 为 <img> 信标兜底通道
    var voteRaw = isPost ? body && body.playerId : u.searchParams.get('vote');
    var wantVote = voteRaw !== undefined && voteRaw !== null && String(voteRaw) !== '';

    // 打捞结算参数
    var scoreRaw = isPost ? body && body.score : u.searchParams.get('score');
    var wantReward = scoreRaw !== undefined && scoreRaw !== null && String(scoreRaw) !== '';

    // 开局取令牌：GET ?gameStart=1
    var wantStart =
      String(u.searchParams.get('gameStart') || '') !== '' ||
      (body && body.gameStart === true);

    try {
      // ---------- 0. 管理口令：只读校验（管理台门禁） ----------
      // 只回答「对不对」。不返回口令、不返回其长度/前缀，也不写任何数据 ——
      // 猜中口令也改不动东西，改数据仍然只能走 live_set / tag_set。
      // 放在最前面：它比其他路由都便宜，且不该被任何写路径的短路顺序影响。
      if (wantAuth) {
        if (keyLocked()) {
          return send(res, 429, { ok: false, reason: 'too_many' }, cb);
        }

        var gKey = String((isPost ? body && body.key : u.searchParams.get('key')) || '')
          .replace(CTRL_RE, '')
          .trim();

        if (!gKey) {
          return send(res, 200, { ok: false, reason: 'bad_key' }, cb);
        }

        var gRes = await restCall('/rpc/admin_check', 'POST', { p_key: gKey });

        if (!gRes || gRes.ok !== true) {
          // 只把「确实比对过且不对」计入试错；数据库抽风不该算用户的账
          if (gRes && gRes.ok === false) keyFails.push(Date.now());
          return send(res, 200, { ok: false, reason: 'bad_key' }, cb);
        }

        return send(res, 200, { ok: true }, cb);
      }

      // ---------- 0. 当前总台：读配置 + 实时开播状态（公开只读） ----------
      if (wantLive && !wantLiveSet) {
        var liveCfg = await restCall('/rpc/live_get', 'POST', {});
        var liveSt =
          liveCfg && ROOM_RE.test(liveCfg.roomId || '') ? await fetchBili(liveCfg.roomId) : null;
        return send(res, 200, { ok: true, live: liveCfg || null, status: liveSt }, cb);
      }

      // ---------- 0b. 当前总台：写入（口令只在服务端比对，永不下发） ----------
      if (wantLiveSet) {
        if (keyLocked()) {
          return send(res, 429, { ok: false, reason: 'too_many' }, cb);
        }

        var aKey = String((isPost ? body && body.key : u.searchParams.get('key')) || '')
          .replace(CTRL_RE, '')
          .trim();
        var aRoom = String((isPost ? body && body.room : u.searchParams.get('room')) || '')
          .replace(CTRL_RE, '')
          .trim();
        var aTitle = (isPost ? body && body.title : u.searchParams.get('title')) || '';
        var aNote = (isPost ? body && body.note : u.searchParams.get('note')) || '';
        var enRaw = isPost ? body && body.enabled : u.searchParams.get('enabled');
        var aEnabled = !(
          enRaw === false ||
          enRaw === 0 ||
          enRaw === '0' ||
          enRaw === 'false' ||
          enRaw === 'off'
        );

        var saved = await restCall('/rpc/live_set', 'POST', {
          p_key: aKey,
          p_room_id: aRoom,
          p_title: cleanStageText(aTitle, 40),
          p_note: cleanStageText(aNote, 60),
          p_enabled: aEnabled,
        });

        if (!saved || saved.ok !== true) {
          if (saved && saved.reason === 'bad_key') keyFails.push(Date.now());
          return send(res, 200, { ok: false, reason: (saved && saved.reason) || 'live_set_failed' }, cb);
        }

        // 房间可能换了，丢掉旧缓存再取一次
        biliCache = { roomId: '', at: 0, data: null };
        var newRoom = (saved.live && saved.live.roomId) || '';
        var st2 = ROOM_RE.test(newRoom) ? await fetchBili(newRoom) : null;
        return send(res, 200, { ok: true, live: saved.live, status: st2 }, cb);
      }

      // ---------- 0c. 选手标签：读（公开只读，不需要设备号） ----------
      if (wantTags && !wantTagSet) {
        var tagsAll = await restCall('/rpc/tag_get', 'POST', {});
        return send(res, 200, { ok: true, tags: tagsAll && typeof tagsAll === 'object' ? tagsAll : {} }, cb);
      }

      // ---------- 0d. 选手标签：写（口令只在服务端比对，整组替换） ----------
      if (wantTagSet) {
        if (keyLocked()) {
          return send(res, 429, { ok: false, reason: 'too_many' }, cb);
        }

        var tKey = String((isPost ? body && body.key : u.searchParams.get('key')) || '')
          .replace(CTRL_RE, '')
          .trim();
        var tPid = toInt(isPost ? (body && body.playerId) : u.searchParams.get('playerId'), 0);
        if (!(tPid >= PLAYER_MIN && tPid <= 999)) {
          return send(res, 200, { ok: false, reason: 'bad_player' }, cb);
        }

        var tList = parseTags(isPost ? (body && body.tags) : u.searchParams.get('tags'));

        var tSaved = await restCall('/rpc/tag_set', 'POST', {
          p_key: tKey,
          p_player_id: tPid,
          p_tags: tList,
        });

        if (!tSaved || tSaved.ok !== true) {
          if (tSaved && tSaved.reason === 'bad_key') keyFails.push(Date.now());
          return send(
            res,
            200,
            { ok: false, reason: (tSaved && tSaved.reason) || 'tag_set_failed' },
            cb
          );
        }
        return send(
          res,
          200,
          {
            ok: true,
            playerId: tPid,
            tags: tSaved.tags || [],
            all: tSaved.all || {},
          },
          cb
        );
      }

      // ---------- 1. 排行榜（公开只读） ----------
      if (wantBoard) {
        var lim = toInt(isPost ? (body && body.limit) : u.searchParams.get('limit'), 20);
        lim = Math.max(BOARD_MIN, Math.min(BOARD_MAX, lim));
        var board = await restCall('/rpc/game_leaderboard', 'POST', { p_limit: lim });
        return send(res, 200, { ok: true, board: board }, cb);
      }

      // ---------- 1. 开局：发本局令牌 ----------
      if (wantStart && !wantVote && !wantReward) {
        var started = await restCall('/rpc/game_start', 'POST', { p_device_id: deviceId });
        var sLimit = BASE_LIMIT + (await readBonus(deviceId));
        var sStatus = await readStatus(deviceId, sLimit);
        var sCounts = await snapshot();
        return send(res, 200, { ok: true, session: started, status: sStatus, counts: sCounts }, cb);
      }

      // ---------- 2. 结算打捞成绩，领额外额度 ----------
      if (wantReward) {
        var score = parseInt(scoreRaw, 10);
        if (isNaN(score) || score < 0 || score > 200000) {
          return send(res, 400, { ok: false, reason: 'bad_score' }, cb);
        }
        var token = String((isPost ? body && body.token : u.searchParams.get('token')) || '').trim();
        if (!TOKEN_RE.test(token)) token = '';

        // 昵称留空则不落排行榜，但奖励照发
        var nick = cleanNick(isPost ? (body && body.nickname) : u.searchParams.get('nickname'));

        var reward = await restCall('/rpc/game_reward', 'POST', {
          p_device_id: deviceId,
          p_token: token,
          p_score: score,
          p_nickname: nick,
          p_layer: Math.max(1, Math.min(999, toInt(
            isPost ? (body && body.layer) : u.searchParams.get('layer'), 1))),
          p_relics: Math.max(0, Math.min(9999, toInt(
            isPost ? (body && body.relics) : u.searchParams.get('relics'), 0))),
          p_combo: Math.max(0, Math.min(9999, toInt(
            isPost ? (body && body.combo) : u.searchParams.get('combo'), 0))),
        });
        var rLimit = BASE_LIMIT + (await readBonus(deviceId));
        var rStatus = await readStatus(deviceId, rLimit);
        var rCounts = await snapshot();
        return send(
          res,
          200,
          { ok: true, reward: reward, status: rStatus, counts: rCounts },
          cb
        );
      }

      // ---------- 3. 投票 ----------
      if (wantVote) {
        var pid = parseInt(voteRaw, 10);
        if (!(pid >= PLAYER_MIN && pid <= PLAYER_MAX)) {
          return send(res, 400, { ok: false, reason: 'bad_player' }, cb);
        }
        var vLimit = BASE_LIMIT + (await readBonus(deviceId));
        var result = await restCall('/rpc/cheer', 'POST', {
          p_player_id: pid,
          p_device_id: deviceId,
          p_limit: vLimit,
        });
        var after = await snapshot();
        return send(res, 200, { ok: true, result: result, counts: after }, cb);
      }

      // ---------- 4. 读状态 ----------
      var limit = BASE_LIMIT + (await readBonus(deviceId));
      var status = await readStatus(deviceId, limit);
      var counts = await snapshot();
      return send(res, 200, { ok: true, status: status, counts: counts }, cb);
    } catch (err) {
      return send(
        res,
        500,
        {
          ok: false,
          reason: 'upstream',
          message: String((err && err.message) || err).slice(0, 180),
        },
        cb
      );
    }
  });
});

server.listen(PORT, '0.0.0.0', function () {
  console.log('cheer api listening on ' + PORT);
});
