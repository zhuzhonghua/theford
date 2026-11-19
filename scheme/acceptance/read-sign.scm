;;; Phase 5 验收：走到村口木牌，用 E 阅读。
;;; GM 中输入：load read-sign
;;;
;;; 从河滩沿村道走过来，走到木牌旁再按 E——回放看得到走位，
;;; 不是瞬移到牌子前面。阅读不改动世界状态，可以反复运行。

(define (acceptance:steps)
  (list
    (list "note" "Phase 5：脚本先把玩家放到河滩起点，再走到村口木牌按 E 阅读" "2.4")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "assert-map" "village")
    (list "note" "沿村道往北，走到铁匠铺门口" "1.6")
    (list "walk" "smithy-door")
    (list "note" "木牌就在门边，走过去按 E" "1.6")
    (list "walk-interact")
    (list "assert-log" "村口木牌")
    (list "gm" "speed 1")
    (list "note" "验收完成：E 动词读到 props/text" "2.0")))
