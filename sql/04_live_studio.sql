-- 04_live_studio.sql
-- 当前总台直播间配置表 + 管理密钥表 + 读写函数
--
-- 由生产环境的部署脚本 apply_live_schema.py 自动导出，按原顺序排列。
-- 全部语句幂等（CREATE ... IF NOT EXISTS / CREATE OR REPLACE），可重复执行。
-- 按文件名序号 01 → 06 依次执行即可建出与线上一致的库。

-- ---------- 建 site_live 表 ----------
CREATE TABLE IF NOT EXISTS public.site_live (
  id         integer     NOT NULL DEFAULT 1,
  room_id    text        NOT NULL DEFAULT '',
  title      text        NOT NULL DEFAULT '',
  note       text        NOT NULL DEFAULT '',
  enabled    boolean     NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT site_live_pkey PRIMARY KEY (id),
  CONSTRAINT site_live_singleton CHECK (id = 1)
);

-- ---------- 建 site_secret 表 ----------
CREATE TABLE IF NOT EXISTS public.site_secret (
  name       text        NOT NULL,
  value      text        NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT site_secret_pkey PRIMARY KEY (name)
);

-- ---------- 建 live_get 函数 ----------
CREATE OR REPLACE FUNCTION public.live_get()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
AS $fn$
  SELECT jsonb_build_object(
    'roomId',  COALESCE((SELECT room_id FROM public.site_live WHERE id = 1), ''),
    'title',   COALESCE((SELECT title   FROM public.site_live WHERE id = 1), ''),
    'note',    COALESCE((SELECT note    FROM public.site_live WHERE id = 1), ''),
    'enabled', COALESCE((SELECT enabled FROM public.site_live WHERE id = 1), true),
    'updatedAt', COALESCE((
      SELECT to_char(updated_at AT TIME ZONE 'Asia/Shanghai', 'MM-DD HH24:MI')
        FROM public.site_live WHERE id = 1
    ), '')
  )
$fn$;

-- ---------- 建 live_set 函数 ----------
CREATE OR REPLACE FUNCTION public.live_set(
  p_key     text,
  p_room_id text,
  p_title   text    DEFAULT '',
  p_note    text    DEFAULT '',
  p_enabled boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE
  v_key   text;
  v_room  text;
  v_title text;
  v_note  text;
BEGIN
  SELECT value INTO v_key FROM public.site_secret WHERE name = 'live_admin_key';
  IF v_key IS NULL OR v_key = '' OR p_key IS NULL OR p_key <> v_key THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_key');
  END IF;

  -- 房间号：只允许纯数字；留空表示「暂无总台」
  v_room := btrim(COALESCE(p_room_id, ''));
  IF v_room <> '' AND v_room !~ '^[0-9]{1,12}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_room');
  END IF;

  -- 标题 / 备注：去控制字符 → 压空白 → 去首尾 → 截断（按字符，中文也算 1）
  v_title := left(btrim(regexp_replace(
    regexp_replace(COALESCE(p_title, ''), '[[:cntrl:]]', '', 'g'), '\s+', ' ', 'g')), 40);
  v_note := left(btrim(regexp_replace(
    regexp_replace(COALESCE(p_note, ''), '[[:cntrl:]]', '', 'g'), '\s+', ' ', 'g')), 60);

  INSERT INTO public.site_live (id, room_id, title, note, enabled, updated_at)
  VALUES (1, v_room, v_title, v_note, COALESCE(p_enabled, true), now())
  ON CONFLICT (id) DO UPDATE
     SET room_id    = EXCLUDED.room_id,
         title      = EXCLUDED.title,
         note       = EXCLUDED.note,
         enabled    = EXCLUDED.enabled,
         updated_at = now();

  RETURN jsonb_build_object('ok', true, 'live', public.live_get());
END
$fn$;

-- ---------- 授权 live_get ----------
GRANT EXECUTE ON FUNCTION public.live_get()
  TO PUBLIC, anon, authenticated, service_role;

-- ---------- 授权 live_set ----------
GRANT EXECUTE ON FUNCTION public.live_set(text, text, text, text, boolean)
  TO PUBLIC, anon, authenticated, service_role;

-- ---------- 写入默认总台 ----------
INSERT INTO public.site_live (id, room_id, title, note, enabled)
VALUES (1, '', '', '', true)
ON CONFLICT (id) DO NOTHING;

-- ---------- 写入管理口令 ----------
-- 管理口令：自己生成一把足够长的随机串，别用弱口令。
-- 建议 28 位以上；示例：  openssl rand -base64 24
INSERT INTO public.site_secret (name, value)
VALUES ('live_admin_key', 'CHANGE-ME-to-a-long-random-string')
ON CONFLICT (name) DO NOTHING;

-- ---------- 通知 PostgREST 重载 ----------
NOTIFY pgrst, 'reload schema';
