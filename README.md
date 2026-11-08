# 《渡口》The Ford — scmllama LLM 村庄 demo

一个本地 LLM 驱动 NPC 的像素村庄切片：
- **引擎**：Godot 4.x（本机 4.7.2），只做表现层
- **脚本**：`scheme/game/main.scm` 拥有全部游戏状态（任务状态机/对话历史/背包）
- **LLM**：scmllama（dummyscheme + llama.cpp）以 GDExtension 形式内嵌，
  本地 Qwen3-0.6B 生成 NPC 台词；无模型时自动回退预置台词，游戏照样可通关
- **素材**：Ninja Adventure（CC0）+ lsw 自绘 CC0 素材

对应计划文档：`llama.cpp-scheme/startup/plan_oss_edu_game.md`（Phase 1 极简切片）。

## 运行

```bash
# 0. 构建 GDExtension（详见 ../llama.cpp-scheme/gdextension/README.md）
cd ~/clojureserver/llama.cpp-scheme
cmake -S . -B build-gd -DSCMLLAMA_BUILD_GDEXTENSION=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DSCMLLAMA_GDENGINE_OUTPUT_DIR=$HOME/clojureserver/theford/addons/scmllama/bin
cmake --build build-gd --target scmllama_gdextension -j

# 1. 用 Godot 打开本项目（demo 模式）：
/Applications/Godot.app/Contents/MacOS/Godot --path ~/clojureserver/theford
# 或直接跑：
/Applications/Godot.app/Contents/MacOS/Godot --path ~/clojureserver/theford scenes/main.tscn
```

模型查找顺序：`$THEFORD_MODEL` → `models/Qwen3-0.6B-Q4_K_M.gguf`（项目自带，不入 git）。

## 玩法（本周切片）

- WASD/方向键走路，E 与 NPC 对话
- 数字键 1-4 选话题；天气、活计、村子的事按话题问
- 走过地上的石头/矿石自动拾取
- 铁匠老王：接任务 → 捡 3 块铁矿石 → 交任务 → 完结
- 陈婆/张掌柜：纯对话（本地 LLM 生成，逐次不同）

## 结构

```
project.godot
assets/            # Ninja Adventure (na/) + lsw 自绘素材 + fonts/ 字体
models/            # 本地 LLM 权重（Qwen3-0.6B-Q4_K_M.gguf，不入 git）
scenes/main.tscn
scripts/
  game_bridge.gd   # autoload "Game"：主线程 ↔ 逻辑线程的 RPC 边界（ScmLlama 独占一条线程）
  main.gd          # 拼装地图/NPC/矿石/UI（TileSet 全部运行时构建）
  player.gd npc.gd dialog.gd
scheme/game/main.scm   # 游戏逻辑全部在这：状态机 + LLM 提议/台词
addons/scmllama/       # GDExtension（bin/ 下的 dylib 由 llama.cpp-scheme 构建产出）
```

## 已知边界（W1 切片如实记录）

- 逻辑线程模型：ScmLlama 实例由专用 worker 线程创建/使用/销毁（dummyscheme 与
  llama_context 非线程安全），主线程通过纯数据消息 `{fn,args,ticket}` 通信；
  LLM 生成期间画面不卡，流式逐 token 输出仍在 TODO
- 消息形状即 RPC：将来把线程队列换成 WebSocket 即可把逻辑移到服务器，游戏代码不动
- 中文用项目自带字体渲染：`assets/fonts/fusion-pixel-12px-proportional-zh_hans.otf.woff2`
  （Fusion Pixel，SIL OFL 许可，见 `assets/fonts/OFL.txt`），不再依赖系统字体
- `res://` scheme 路径只在编辑器/调试模式下指向项目目录（导出版需改造为 PCK 内读文件）
- 网页版跑不了原生库：按计划用录屏 + 可执行文件下载（plan §3.3 方案 B）
