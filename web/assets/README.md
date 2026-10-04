# assets/ —— 需要你自己准备的图片素材

本仓库**不包含任何美术素材**。站点引用到的图片路径如下，把同名文件放进对应目录即可正常渲染。

## `bg/` —— 页面背景

| 文件 | 用途 |
| --- | --- |
| `theme_lobby.png` | 首页大厅主视觉背景 |
| `the_hunt_screen.png` | 打捞小游戏页面背景 |
| `layer1_transition.png` | 小游戏进层过场（第 1 阶段） |
| `layer3_transition.png` | 小游戏进层过场（第 3 阶段） |

## `relics/` —— 48 件藏品单图

文件名见 `assets/data/relics.json` 中的 `img` 字段，形如 `relic_01_zhongji.jpg`。
`_zhongji` / `_daji` / `_xiaoji` / `_ping` / `_hongyun` / `_xiong` 后缀对应 6 档吉凶特效。

## `rules/` —— 赛事规程长图切片

见 `assets/data/rules_slices.json`。原设计是把两张超长规则图切成 9 段分段加载。

## `data/` —— 数据是占位内容

`relics.json` 里藏品的**名称、效果、说明全部是原创占位文本**（`藏品01`…`藏品48`），
`players.json` 里选手也是占位数据。这些都不是游戏内文本，请你替换成自己的内容。

---

**为什么没有附素材？** 这些图片是《明日方舟》游戏内的美术资产，版权属于鹰角网络。
本仓库只开源代码，不分发这些素材。详见根目录 `NOTICE` 与 `DISCLAIMER.md`。
