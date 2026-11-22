;;; Phase 7 验收（7.4）：生命归零出现结束画面，按 R 从渡口重新开始。
;;; GM 中输入：load game-over

(define (acceptance:steps)
  (list
    (list "note" "Phase 7：先确认起始生命满格，结束画面还没出现" "2.6")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "assert-map" "village")
    (list "assert-hp" "10")
    (list "assert-game-over" "closed")
    (list "note" "用 GM 把生命打空，等价于被史莱姆咬到倒下" "2.0")
    (list "gm" "hurt 10")
    (list "assert-hp" "0")
    (list "assert-game-over" "open")
    (list "note" "按 R：Scheme 回到开局，地图重建，玩家站在河口出生点" "2.4")
    (list "press" "R")
    (list "wait" "3.0")
    (list "assert-game-over" "closed")
    (list "assert-map" "village")
    (list "assert-near" "riverbank")
    (list "assert-hp" "10")
    (list "gm" "speed 1")
    (list "note" "验收完成：死亡画面与重开都通过" "2.4")))
