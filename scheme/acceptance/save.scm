;;; Phase 11 验收：存档 / 读档。
;;; GM 中输入：load save
;;;
;;; 先攒出一份可辨认的状态（背包、时钟、天气、生命），按 F5 快存；随后故意
;;; 把状态改乱并热重载回开局，再按 F9 读档，断言所有值都回到存档那一刻。
;;; 存档同时包含 Godot 住的地图与站位、Scheme 住的背包/任务/时钟/learned。
;;; 脚本不还原场景：跑完后玩家可以直接继续玩。

(define (acceptance:steps)
  (list
    (list "note" "存档验收：先攒一点状态，再按 F5 快存" "2.6")
    (list "delete-save")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "gm" "give ore 3")
    (list "gm" "give stone 2")
    (list "gm" "time 14:00")
    (list "gm" "weather rain")
    (list "gm" "hurt 3")
    (list "assert-clock" "14:00")
    (list "assert-hp" "7")
    (list "assert-bag" "item/material/ore" "3")
    (list "assert-bag" "item/material/stone" "2")

    (list "note" "按 F5：背包 / 任务 / 时钟 / 天气 / 生命连同地图与站位一起写进 user://save1.scm" "3.0")
    (list "press" "F5")
    (list "wait" "1.2")
    (list "assert-save-exists")
    (list "assert-save-text" "((version 1)")
    (list "assert-save-text" "item/material/ore")
    (list "assert-log" "已存档：")

    (list "note" "现在故意改乱状态：多塞矿、改时间、改天气、回血，再热重载回开局" "3.0")
    (list "gm" "give ore 5")
    (list "assert-bag" "item/material/ore" "8")
    (list "gm" "time 09:00")
    (list "gm" "weather sun")
    (list "gm" "heal")
    (list "gm" "reload")
    ;; GM reload resets the debug speed to 1, so pause the clock again before
    ;; asserting an exact minute.
    (list "gm" "speed 0")
    (list "assert-bag" "item/material/ore" "0")
    (list "assert-clock" "08")
    (list "assert-hp" "10")

    (list "note" "按 F9 读档：地图、背包、时钟、天气与生命都要回到存档那一刻" "3.0")
    (list "press" "F9")
    (list "wait" "3.0")
    (list "assert-log" "已读档：")
    (list "assert-map" "village")
    (list "assert-bag" "item/material/ore" "3")
    (list "assert-bag" "item/material/stone" "2")
    (list "assert-hp" "7")
    (list "assert-clock" "14:00")
    (list "assert-prompt-contains" "smith" "village" "天气：下雨")

    (list "note" "再走一次 GM 指令读档，确认读档后的状态还能稳定往返" "2.8")
    (list "gm" "loadgame")
    (list "assert-bag" "item/material/ore" "3")
    (list "assert-clock" "14:00")
    (list "assert-hp" "7")

    (list "note" "存档损坏时要有提示：删掉存档再读一次，HUD 应显示读档失败" "2.8")
    (list "delete-save")
    (list "gm" "loadgame")
    (list "assert-log" "读档失败")

    (list "gm" "speed 1")
    (list "note" "验收完成：F5 存档 / F9 读档往返一致，失败也有提示" "2.6")))
