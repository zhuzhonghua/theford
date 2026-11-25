# 《渡口》The Ford — scmllama LLM 村庄 demo

[English](README.md) | 简体中文

一个本地 LLM 驱动 NPC 的像素村庄切片：

<img src="readme-demo.gif" width="720" alt="老王拒绝交矿石：HUD 显示意图 GIVE、Scheme 判定拒绝、台词来源剧本台词">

*HUD 把规则显影：玩家想交矿石，但背上是 0 块。Scheme 拒绝这次动作，拒绝台词由剧本确定，不经过模型。*

- **引擎**：Godot 4.x（本机 4.7.2），只做表现层
- **脚本**：`scheme/game/main.scm` 拥有全部游戏状态（任务状态机/对话历史/背包）
- **LLM**：scmllama（dummyscheme + llama.cpp）以 GDExtension 形式内嵌，
  本地 Qwen3-0.6B 生成 NPC 台词；无模型时自动回退预置台词，游戏照样可通关
- **素材**：Ninja Adventure（CC0）+ lsw 自绘 CC0 素材

## 运行

```bash
# 0. 克隆本项目
git clone --depth=1 https://github.com/zhuzhonghua/theford.git

# 1. 克隆并构建 GDExtension（含 llama.cpp-scheme 与 godot-cpp 两个 submodule，
#    与本项目并排放；输出直接写进本项目的 addons 目录）
git clone https://github.com/zhuzhonghua/scmllama-extensions.git
cd scmllama-extensions
git submodule update --init --recursive
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DSCMLLAMA_GDENGINE_OUTPUT_DIR=../theford/addons/scmllama/bin
cmake --build build --target scmllama_gdextension -j

# 2. 用 Godot 4.5+ 打开 theford 目录，或命令行运行：
#    macOS: /Applications/Godot.app/Contents/MacOS/Godot --path ../theford
#    Linux: godot --path ../theford
```

平台：目前仅在 macOS arm64 上验证（`.gdextension` 只注册了 macos 条目）；
Linux/Windows 需在对应平台构建扩展，并在该文件里补对应条目。

### 导出（macOS）

`export_presets.cfg` 里带了一个 macOS 预设。在 Godot 装好对应导出模板后：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --export-release "macOS" "$PWD/export/The Ford.app"
```

原生 Scheme VM 用 `fopen` 读文件，看不到 PCK 内部。首次启动时 bridge 会把
`res://scheme/` 里的 .scm 解包到 `user://scheme_pck/`，再让 VM 读这个真实目录；
编辑器里仍直接用项目目录，所以热重载依然能读到刚改的内容。预设的
`include_filter` 显式包含 `*.scm`（Godot 把它们当纯文本，默认不会导出）。

378 MB 的 GGUF **不**打进 app：把它拷到可执行文件旁（或 app 包的
`Contents/Resources/`），或用 `$THEFORD_MODEL` 指向绝对路径。没有模型也能玩，只是用预置台词。

模型查找顺序：`$THEFORD_MODEL` → `models/Qwen3-0.6B-Q4_K_M.gguf`（编辑器）或导出程序旁的
同名文件 → `user://`。模型文件不入 git。设 `THEFORD_AI_QUALITY=0`（或 `off`）可
**完全不加载模型**：NPC 用预置台词，游戏照样能通关。
四档为 `off` / `low`（64 tok）/ `medium`（默认 120 tok）/ `high`（200 tok）；高档生成的台词可供低档回放，反之不行。


## 玩法

- WASD/方向键走路，E 与 NPC 对话
- 数字键 1-4 选话题；天气、活计、村子的事按话题问
- 走到掉落物（矿石、砍下的原木）两格内自动吸进背包；背包 30 格、每格同种最多 999，工具一件一槽
- **I** 打开背包面板：三行十格，显示物品图标与数量，装备的工具描金边；拾取时面板即时刷新
- 工具要"装备"才生效：捡到斧头只是进背包，F 砍不动；在背包里点工具格装备
  （面板顶部"手"槽位框会显示图标，点它卸下）后 F 才挥得动。GM 也支持 `equip axe` / `unequip`
- 河滩上有**史莱姆**：靠近会追人、贴身咬掉 1 点生命；F 优先打手边的史莱姆（比砍树优先），
  斧头 3 下（power 3 对 8 血）击杀，掉落的凝胶会被磁吸进背包。HUD 顶行显示生命 `♥ 10/10`；
  生命归零出现结束画面（带死亡音效），按 **R** 从河口出生点重开
- 村民看到史莱姆会**逃跑**，威胁离开后回到自己的日程
- **三幕剧情**：走到河滩自动开场 → 交完矿石后老王重铸绞盘 → 找张掌柜接「谁剪断了缆绳」（问原委、看泥印、看断缆）→ 找老王接「重开渡船」（问阿笋、接缆绳）→ 渡船重开、信送到对岸。剧情节点由 `scheme/game/story.scm` 的 beat/fact 决断，演出时按 E/Enter 逐句推进、Esc 跳过；剧情事实也进 NPC 的 prompt
- 铁匠老王：接任务 → 捡 3 块铁矿石 → 交任务 → 完结
- 陈婆/张掌柜：纯对话（本地 LLM 生成，逐次不同）
- **音频**：村庄 BGM 循环播放；脚步声跟着实际走过的距离响（音高微随机）；下雨时雨声淡入、
  进屋后消失；拾取/砍树/命中/击杀/对话/任务完成/死亡各有对应音效，Music 与 SFX 分轨。
  音效路径都在 `scheme/game/data/catalog.scm`；`THEFORD_DEBUG_AUDIO=1` 可打印每次播放
- **HUD 按参考项目做成四角布局**：左上可点击小地图、右上钟盒+任务目标、底部中央生命/经验/手持与当前动作提示、右下 40px 木纹图标按钮（状态/日志/地图/帮助/背包/任务/音量/机制/GM，**不含存档读档**，用 F5/F9 或 GM）；左下是自动淡出的消息栈——按 E 读牌、砍树、拾取等反馈会在这里出现几秒，不再"按了没提示"。面板统一羊皮纸底 + 木框 + 标题栏像素 ✕ 关闭按钮；世界地图是左侧点阵示意图 + 右侧名单，不再标签重叠。快捷键仍保留
- **O** 打开音量面板：主音量 / 音乐 / 音效各一个滑条，拖动即时生效；设置写入
  `user://settings.cfg`，下次启动自动恢复。GM 也支持 `volume` 查看与设置
  （`volume master 50`、`volume music 30`、`volume sfx 70`、`volume reload`）
- **F1** 打开"机制 HUD"：话题 → 意图、Scheme 判定、台词来源（LLM / 缓存 / 剧本）、
  模型名与 AI 档位、prefill/decode 速度；`THEFORD_MECHANISM=0` 可关闭
- **F5** 快存、**F9** 快读，单槽位写在 `user://save1.scm`：存档是用项目自己的 `table` DSL 写成的
  Scheme 源码，背包、任务、剧情事实、时钟、天气、生命、learned 台词、当前地图与人物站位都能往返；读档失败会显示提示。
  启动时弹出「继续游戏 / 新游戏」菜单（无存档时继续置灰）。热重载只用 GM `reload`，F5 不再是热重载
- **F8** 打开 GM 控制台：`time 11:00` 跳时钟、`speed 10` 加速时间、
  `weather rain` 强制天气、`npc smith inn-yard` 覆盖日程、`people` 查看状态；
  `bag` 开关背包面板、`give ore 3` 塞物品、`equip axe` 装备工具、`volume` 查看音量、
  `quality off|medium` 查看或切换 AI 档位，`prompt smith village` 把该回合的 LLM prompt 打到控制台（含时辰/天气/日程情境行）；
  `story` 查看剧情事实、`story beat <id>` 手动触发 beat；
  `hp` / `hurt 10` / `heal` 查看或改变生命、`slime smith` 把史莱姆引到村民旁、`restart` 重开、
  `save` 快存 / `loadgame` 快读 / `reload` 热重载；
  `load combat` / `load game-over` / `load flee` / `load audio` / `load volume` / `load quality` / `load prompt` / `load story` / `load story-chain` / `load ui-panels` 回放验收；输入 `help` 看全部指令。
  终端里用 `THEFORD_ACCEPTANCE=<name> THEFORD_ACCEPTANCE_QUIT=1` 无头回放会自动快跑（演出等待压缩、打字机直显，通常几秒到二十秒）；在窗口里用 GM `load` 手动观看则保持正常节奏。
  批量跑全部验收用 `./scripts/run_acceptance.sh`（默认 4 个进程并行，`JOBS=8` 可调；默认 `THEFORD_AI_QUALITY=off`）；21 个脚本约 65 秒，失败会打印对应日志。并行而非串行是因为每个脚本独立进程、冷启动和模型加载重复，而 note/wait 早已在 headless 模式下压缩为 1 帧
- 也可以直接输入中文：`让老王去酒馆`、`把时间暂停`，本地模型会翻译成一条确定性指令
  （`npc smith inn-yard drinking`、`speed 0`）再执行，日志里会显示 `LLM → …`。
  生成受 grammar 约束，模型只能输出合法指令
- GM 是独立模块，发布时整体删除 `scripts/gm/` 与 `scheme/game/gm.scm`，再去掉
  `scheme/game/main.scm` 末尾的 `(require "game.gm")` 即可；主游戏不依赖它

## 已知边界

- 中文用项目自带字体渲染：`assets/fonts/fusion-pixel-12px-proportional-zh_hans.otf.woff2`
  （Fusion Pixel，SIL OFL 许可，见 `assets/fonts/OFL.txt`），已设为项目全局默认字体，不依赖系统字体
- 导出的 macOS app 除可选的 GGUF 模型外自包含（见「导出」一节）；存档与音量设置放在
  `user://`，不受 scheme 解包目录影响
