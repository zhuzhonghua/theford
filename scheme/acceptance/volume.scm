;;; Phase 9.4 验收：主 / 音乐 / 音效三条总线的音量滑条与持久化。
;;; GM 中输入：load volume
;;;
;;; 先按 O 开面板，逐个拖动滑条并断言总线音量、滑条百分比与 settings.cfg；
;;; 然后关面板、模拟重开（gm volume reload）再开，确认滑条显示磁盘上的值。
;;; 最后恢复验收前的音量，不改动玩家平时的设置。Esc 是验收中止键，
;;; 所以开关面板一律用 O（与玩家手动按键同一条路径）。

(define (acceptance:steps)
  (list
    (list "note" "Phase 9.4：按 O 打开音量设置，三条总线各有一个滑条" "2.4")
    (list "backup-audio-settings")
    (list "press" "o")
    (list "assert-volume-panel" "open")

    (list "note" "拖动主音量到 50%：总线与滑条即时同步，并写入设置" "2.0")
    (list "set-volume" "master" "0.5")
    (list "assert-volume" "master" "0.5")
    (list "assert-volume-saved")

    (list "note" "音乐拖到 30%：只影响 Music 总线" "1.6")
    (list "set-volume" "music" "0.3")
    (list "assert-volume" "music" "0.3")
    (list "assert-volume" "master" "0.5")
    (list "assert-volume-saved")

    (list "note" "音效拖到 70%：三条总线互不影响" "1.6")
    (list "set-volume" "sfx" "0.7")
    (list "assert-volume" "sfx" "0.7")
    (list "assert-volume" "music" "0.3")
    (list "assert-volume-saved")

    (list "note" "按 O 收起面板（也会立刻落盘）" "1.6")
    (list "press" "o")
    (list "assert-volume-panel" "closed")

    (list "note" "模拟重开游戏：从 settings.cfg 重读，三档音量应保持" "2.0")
    (list "gm" "volume reload")
    (list "assert-volume" "master" "0.5")
    (list "assert-volume" "music" "0.3")
    (list "assert-volume" "sfx" "0.7")
    (list "assert-volume-saved")

    (list "note" "再按 O 打开：滑条显示的就是磁盘上的值" "2.0")
    (list "press" "o")
    (list "assert-volume-panel" "open")
    (list "assert-volume" "master" "0.5")
    (list "assert-volume" "music" "0.3")
    (list "assert-volume" "sfx" "0.7")
    (list "press" "o")
    (list "assert-volume-panel" "closed")

    (list "note" "恢复验收前的音量，不留下副作用" "1.6")
    (list "restore-audio-settings")
    (list "assert-volume-saved")
    (list "gm" "volume")
    (list "note" "验收完成：滑条实时生效，重开保持" "2.0")))
