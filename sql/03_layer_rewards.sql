-- 03_layer_rewards.sql
-- 兑奖档位从「打捞分」改为「抵达层数」（N 层 = N×5 次，封顶 50）
--
-- 由生产环境的部署脚本 apply_layer_schema.py 自动导出，按原顺序排列。
-- 全部语句幂等（CREATE ... IF NOT EXISTS / CREATE OR REPLACE），可重复执行。
-- 按文件名序号 01 → 06 依次执行即可建出与线上一致的库。

-- ---------- 建层数档位函数 ----------
CREATE OR REPLACE FUNCTION public.game_layer_tier(p_layer integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  SELECT LEAST(50, GREATEST(0, COALESCE(p_layer, 0)) * 5)
$fn$;

-- ---------- cheer_bonus 补 best_layer ----------
ALTER TABLE public.cheer_bonus
  ADD COLUMN IF NOT EXISTS best_layer integer NOT NULL DEFAULT 0;

-- ---------- 替换结算函数 ----------
CREATE OR REPLACE FUNCTION public.game_reward(
  p_device_id text,
  p_token     text,
  p_score     integer,
  p_nickname  text    DEFAULT '',
  p_layer     integer DEFAULT 1,
  p_relics    integer DEFAULT 0,
  p_combo     integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE
  v_day      date := (now() AT TIME ZONE 'Asia/Shanghai')::date;
  v_score    integer;
  v_votes    integer;
  v_old      integer := 0;
  v_best     integer := 0;
  v_best_lay integer := 0;
  v_plays    integer := 0;
  v_bonus    integer;
  v_tok      record;
  v_nick     text;
  v_layer    integer;
  v_relics   integer;
  v_combo    integer;
  v_rank     integer := 0;
BEGIN
  IF p_device_id IS NULL OR p_device_id !~ '^[A-Za-z0-9_-]{8,64}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_device');
  END IF;

  v_score  := GREATEST(0, LEAST(COALESCE(p_score, 0), 200000));
  v_nick   := public.game_nick_clean(p_nickname);
  v_layer  := GREATEST(1, LEAST(999, COALESCE(p_layer, 1)));
  v_relics := GREATEST(0, LEAST(9999, COALESCE(p_relics, 0)));
  v_combo  := GREATEST(0, LEAST(9999, COALESCE(p_combo, 0)));

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

  -- 档位只看抵达层数，与打捞分无关
  v_votes := public.game_layer_tier(v_layer);

  SELECT bonus, best_score, best_layer, plays
    INTO v_old, v_best, v_best_lay, v_plays
    FROM public.cheer_bonus
   WHERE device_id = p_device_id AND day = v_day
   FOR UPDATE;
  IF NOT FOUND THEN
    v_old := 0; v_best := 0; v_best_lay := 0; v_plays := 0;
  END IF;

  -- 当日额度只升不降：拿今日最好的一局
  v_bonus    := LEAST(50, GREATEST(v_old, v_votes));
  v_best     := GREATEST(v_best, v_score);
  v_best_lay := GREATEST(COALESCE(v_best_lay, 0), v_layer);
  v_plays    := v_plays + 1;

  INSERT INTO public.cheer_bonus
    (device_id, day, bonus, best_score, best_layer, plays, updated_at)
  VALUES
    (p_device_id, v_day, v_bonus, v_best, v_best_lay, v_plays, now())
  ON CONFLICT (device_id, day) DO UPDATE
     SET bonus      = EXCLUDED.bonus,
         best_score = EXCLUDED.best_score,
         best_layer = EXCLUDED.best_layer,
         plays      = EXCLUDED.plays,
         updated_at = now();

  -- 昵称为空 → 不落榜（需求：不输入则不记录成绩）
  -- 昵称非空 → 整行只在「不差于现有纪录」时覆盖（含昵称），
  --             避免低分局的名字盖到高分纪录上、分数与名字对不上
  IF v_nick <> '' THEN
    INSERT INTO public.game_score
      (device_id, nickname, score, layer, relics, best_combo, day, updated_at)
    VALUES
      (p_device_id, v_nick, v_score, v_layer, v_relics, v_combo, v_day, now())
    ON CONFLICT (device_id) DO UPDATE
       SET nickname   = EXCLUDED.nickname,
           score      = EXCLUDED.score,
           layer      = EXCLUDED.layer,
           relics     = EXCLUDED.relics,
           best_combo = EXCLUDED.best_combo,
           day        = EXCLUDED.day,
           updated_at = now()
     WHERE EXCLUDED.score >= public.game_score.score;

    SELECT count(*) + 1 INTO v_rank
      FROM public.game_score
     WHERE score > (SELECT score FROM public.game_score WHERE device_id = p_device_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'bonus', v_bonus,
    'gained', v_bonus - v_old,
    'layer', v_layer,
    'votes', v_votes,
    'bestLayer', v_best_lay,
    'votesPerLayer', 5,
    'tierBonus', v_votes,
    'score', v_score,
    'bestScore', v_best,
    'plays', v_plays,
    'limit', 50 + v_bonus,
    'ranked', v_nick <> '',
    'nickname', v_nick,
    'rank', v_rank
  );
END
$fn$;

-- ---------- 授权 game_layer_tier ----------
GRANT EXECUTE ON FUNCTION public.game_layer_tier(integer)
  TO PUBLIC, anon, authenticated, service_role;

-- ---------- 重授权 game_reward ----------
GRANT EXECUTE ON FUNCTION
  public.game_reward(text, text, integer, text, integer, integer, integer)
  TO PUBLIC, anon, authenticated, service_role;

-- ---------- 删掉旧的分数档位函数 ----------
DROP FUNCTION IF EXISTS public.game_tier(integer);

-- ---------- 通知 PostgREST 重载 ----------
NOTIFY pgrst, 'reload schema';
