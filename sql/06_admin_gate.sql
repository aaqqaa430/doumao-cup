-- 06_admin_gate.sql
-- 管理台门禁：只读验钥函数，不写任何数据
--
-- 由生产环境的部署脚本 apply_admin_check.py 自动导出，按原顺序排列。
-- 全部语句幂等（CREATE ... IF NOT EXISTS / CREATE OR REPLACE），可重复执行。
-- 按文件名序号 01 → 06 依次执行即可建出与线上一致的库。

-- ---------- 建 admin_check 函数 ----------
CREATE OR REPLACE FUNCTION public.admin_check(p_key text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_key text;
BEGIN
  SELECT value INTO v_key FROM public.site_secret WHERE name = 'live_admin_key';

  -- 口令未初始化 / 传空 / 不相等，一律只回 false。
  -- 注意：不能用 v_key IS NULL 直接短路后还留下信息差异 —— 三种情况返回体完全一样。
  IF v_key IS NULL OR v_key = '' OR p_key IS NULL OR p_key = '' OR p_key <> v_key THEN
    RETURN jsonb_build_object('ok', false);
  END IF;

  RETURN jsonb_build_object('ok', true);
END
$fn$;

-- ---------- 授权 admin_check ----------
GRANT EXECUTE ON FUNCTION public.admin_check(text)
  TO PUBLIC, anon, authenticated, service_role;

-- ---------- 通知 PostgREST 重载 ----------
NOTIFY pgrst, 'reload schema';
