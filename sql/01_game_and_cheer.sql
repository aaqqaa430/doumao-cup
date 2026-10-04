-- 01_game_and_cheer.sql
-- 打捞小游戏基础表（每日额度、单局令牌）+ 应援计数与投票函数
--
-- 由生产环境的部署脚本 apply_schema.py 自动导出，按原顺序排列。
-- 全部语句幂等（CREATE ... IF NOT EXISTS / CREATE OR REPLACE），可重复执行。
-- 按文件名序号 01 → 06 依次执行即可建出与线上一致的库。

-- ---------- 建表 cheer_bonus ----------
CREATE TABLE IF NOT EXISTS public.cheer_bonus (
  device_id  text        NOT NULL,
  day        date        NOT NULL,
  bonus      integer     NOT NULL DEFAULT 0,
  best_score integer     NOT NULL DEFAULT 0,
  plays      integer     NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cheer_bonus_pkey PRIMARY KEY (device_id, day)
);

-- ---------- 建表 cheer_game_token ----------
CREATE TABLE IF NOT EXISTS public.cheer_game_token (
  token      text        NOT NULL,
  device_id  text        NOT NULL,
  day        date        NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  used       boolean     NOT NULL DEFAULT false,
  CONSTRAINT cheer_game_token_pkey PRIMARY KEY (token)
);

-- ---------- 索引 token.started_at ----------
CREATE INDEX IF NOT EXISTS cheer_game_token_started_idx
  ON public.cheer_game_token (started_at);

-- ---------- 授权 cheer_bonus ----------
GRANT SELECT ON public.cheer_bonus TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.cheer_bonus TO authenticated, service_role;

-- ---------- 授权 cheer_game_token ----------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.cheer_game_token TO service_role;

-- ---------- 函数 game_tier ----------
CREATE OR REPLACE FUNCTION public.game_tier(p_score integer)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN p_score >= 6000 THEN 50
    WHEN p_score >= 3500 THEN 30
    WHEN p_score >= 2000 THEN 20
    WHEN p_score >= 800  THEN 10
    ELSE 0
  END
$fn$;

-- ---------- 函数 game_bonus ----------
CREATE OR REPLACE FUNCTION public.game_bonus(p_device_id text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE v integer;
BEGIN
  IF p_device_id IS NULL OR p_device_id !~ '^[A-Za-z0-9_-]{8,64}$' THEN
    RETURN 0;
  END IF;
  SELECT bonus INTO v FROM public.cheer_bonus
   WHERE device_id = p_device_id
     AND day = (now() AT TIME ZONE 'Asia/Shanghai')::date;
  RETURN COALESCE(v, 0);
END
$fn$;

-- ---------- 函数 game_start ----------
CREATE OR REPLACE FUNCTION public.game_start(p_device_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE
  v_day   date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
  v_token text;
BEGIN
  IF p_device_id IS NULL OR p_device_id !~ '^[A-Za-z0-9_-]{8,64}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_device');
  END IF;

  v_token := md5(random()::text || clock_timestamp()::text || txid_current()::text)
             || substr(md5(random()::text || p_device_id), 1, 8);

  DELETE FROM public.cheer_game_token WHERE started_at < now() - interval '2 hours';

  INSERT INTO public.cheer_game_token (token, device_id, day, started_at, used)
  VALUES (v_token, p_device_id, v_day, now(), false);

  RETURN jsonb_build_object('ok', true, 'token', v_token, 'day', v_day);
END
$fn$;

-- ---------- 函数 game_reward ----------
CREATE OR REPLACE FUNCTION public.game_reward(p_device_id text, p_token text, p_score integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE
  v_day   date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
  v_score integer;
  v_new   integer;
  v_old   integer := 0;
  v_best  integer := 0;
  v_plays integer := 0;
  v_bonus integer;
  v_tok   record;
BEGIN
  IF p_device_id IS NULL OR p_device_id !~ '^[A-Za-z0-9_-]{8,64}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_device');
  END IF;

  v_score := GREATEST(0, LEAST(COALESCE(p_score, 0), 200000));

  SELECT * INTO v_tok
    FROM public.cheer_game_token
   WHERE token = COALESCE(p_token, '')
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_session');
  END IF;
  IF v_tok.device_id <> p_device_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'session_mismatch');
  END IF;
  IF v_tok.used THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'session_used');
  END IF;
  IF now() - v_tok.started_at < interval '8 seconds' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_fast');
  END IF;

  UPDATE public.cheer_game_token SET used = true WHERE token = v_tok.token;

  v_new := public.game_tier(v_score);

  SELECT bonus, best_score, plays INTO v_old, v_best, v_plays
    FROM public.cheer_bonus
   WHERE device_id = p_device_id AND day = v_day
   FOR UPDATE;
  IF NOT FOUND THEN
    v_old := 0; v_best := 0; v_plays := 0;
  END IF;

  v_bonus := LEAST(50, GREATEST(v_old, v_new));
  v_best  := GREATEST(v_best, v_score);
  v_plays := v_plays + 1;

  INSERT INTO public.cheer_bonus (device_id, day, bonus, best_score, plays, updated_at)
  VALUES (p_device_id, v_day, v_bonus, v_best, v_plays, now())
  ON CONFLICT (device_id, day) DO UPDATE
     SET bonus      = EXCLUDED.bonus,
         best_score = EXCLUDED.best_score,
         plays      = EXCLUDED.plays,
         updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'bonus', v_bonus,
    'gained', v_bonus - v_old,
    'tierBonus', v_new,
    'score', v_score,
    'bestScore', v_best,
    'plays', v_plays,
    'limit', 50 + v_bonus
  );
END
$fn$;

-- ---------- 授权新函数 ----------
GRANT EXECUTE ON FUNCTION public.game_tier(integer) TO PUBLIC, anon, authenticated, service_role;

-- ---------- 授权 game_bonus ----------
GRANT EXECUTE ON FUNCTION public.game_bonus(text) TO PUBLIC, anon, authenticated, service_role;

-- ---------- 授权 game_start ----------
GRANT EXECUTE ON FUNCTION public.game_start(text) TO PUBLIC, anon, authenticated, service_role;

-- ---------- 授权 game_reward ----------
GRANT EXECUTE ON FUNCTION public.game_reward(text,text,integer) TO PUBLIC, anon, authenticated, service_role;

-- ---------- 刷新 PostgREST schema cache ----------
NOTIFY pgrst, 'reload schema';
