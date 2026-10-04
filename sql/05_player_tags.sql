-- 05_player_tags.sql
-- 选手标签表（整组替换语义）+ 只读/写入函数
--
-- 由生产环境的部署脚本 apply_tag_schema.py 自动导出，按原顺序排列。
-- 全部语句幂等（CREATE ... IF NOT EXISTS / CREATE OR REPLACE），可重复执行。
-- 按文件名序号 01 → 06 依次执行即可建出与线上一致的库。

-- ---------- 建 player_tag 表 ----------
CREATE TABLE IF NOT EXISTS public.player_tag (
  player_id  integer     NOT NULL,
  tag        text        NOT NULL,
  sort       integer     NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT player_tag_pkey PRIMARY KEY (player_id, tag),
  CONSTRAINT player_tag_len  CHECK (char_length(tag) BETWEEN 1 AND 12)
);

-- ---------- 建 player_tag 排序索引 ----------
CREATE INDEX IF NOT EXISTS player_tag_order_idx ON public.player_tag (player_id, sort);

-- ---------- 建 tag_get 函数 ----------
CREATE OR REPLACE FUNCTION public.tag_get()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
AS $fn$
  SELECT COALESCE(jsonb_object_agg(t.player_id::text, t.tags), '{}'::jsonb)
  FROM (
    SELECT player_id, jsonb_agg(tag ORDER BY sort, tag) AS tags
      FROM public.player_tag
     GROUP BY player_id
  ) t
$fn$;

-- ---------- 建 tag_set 函数 ----------
CREATE OR REPLACE FUNCTION public.tag_set(
  p_key       text,
  p_player_id integer,
  p_tags      jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE
  v_key  text;
  v_tag  text;
  v_i    integer := 0;
  v_seen text[]  := ARRAY[]::text[];
BEGIN
  SELECT value INTO v_key FROM public.site_secret WHERE name = 'tag_admin_key';
  IF v_key IS NULL OR v_key = '' OR p_key IS NULL OR p_key <> v_key THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_key');
  END IF;

  IF p_player_id IS NULL OR p_player_id < 1 OR p_player_id > 999 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_player');
  END IF;

  IF p_tags IS NULL OR jsonb_typeof(p_tags) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_tags');
  END IF;

  IF jsonb_array_length(p_tags) > 6 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_tags');
  END IF;

  -- 整组替换：先清空该选手，再按顺序写入
  DELETE FROM public.player_tag WHERE player_id = p_player_id;

  FOR v_tag IN SELECT jsonb_array_elements_text(p_tags) LOOP
    -- 去控制字符 → 压空白 → 去首尾 → 截到 12 字（按字符，中文算 1）
    v_tag := left(btrim(regexp_replace(
      regexp_replace(COALESCE(v_tag, ''), '[[:cntrl:]]', '', 'g'),
      '[[:space:]]+', ' ', 'g')), 12);
    CONTINUE WHEN v_tag = '';
    CONTINUE WHEN v_tag = ANY (v_seen);
    v_seen := array_append(v_seen, v_tag);
    INSERT INTO public.player_tag (player_id, tag, sort, updated_at)
    VALUES (p_player_id, v_tag, v_i, now());
    v_i := v_i + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'playerId', p_player_id,
    'tags', COALESCE((
      SELECT jsonb_agg(tag ORDER BY sort, tag)
        FROM public.player_tag WHERE player_id = p_player_id
    ), '[]'::jsonb),
    'all', public.tag_get()
  );
END
$fn$;

-- ---------- 授权 tag_get ----------
GRANT EXECUTE ON FUNCTION public.tag_get()
  TO PUBLIC, anon, authenticated, service_role;

-- ---------- 授权 tag_set ----------
GRANT EXECUTE ON FUNCTION public.tag_set(text, integer, jsonb)
  TO PUBLIC, anon, authenticated, service_role;

-- ---------- 预置 player 1 的完赛标签 ----------
INSERT INTO public.player_tag (player_id, tag, sort)
VALUES (1, '完赛', 0)
ON CONFLICT (player_id, tag) DO NOTHING;

-- ---------- 通知 PostgREST 重载 ----------
NOTIFY pgrst, 'reload schema';
