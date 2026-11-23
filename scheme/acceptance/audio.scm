;;; Phase 9 验收：环境音景（脚步 / 雨声随天气与室内外切换）与事件音效 cue。
;;; GM 中输入：load audio
;;;
;;; 先晴天后下雨，再走进铁匠铺（屋顶下雨声停）、开对话拿开/关与打字音，
;;; 最后回村确认雨声恢复。声音断言读 Audio 的播放计数/环境音状态——路径
;;; 首次使用要经逻辑线程解析，所以每个动作后留出观察时间。

(define (acceptance:steps)
  (list
    (list "note" "Phase 9：先暂停时间，晴天出门走路听脚步声" "2.4")
    (list "gm" "speed 0")
    (list "gm" "weather sun")
    (list "place" "village" "village:riverbank")
    (list "assert-ambience" "rain" "off")

    (list "note" "沿村道走向铁匠铺，脚步应随步子落下" "2.0")
    (list "walk" "smithy-door")
    (list "assert-audio" "footstep" "2")

    (list "note" "改成雨天，雨声应淡入" "1.6")
    (list "gm" "weather rain")
    (list "wait" "0.6")
    (list "assert-ambience" "rain" "on")

    (list "note" "进屋：屋顶下雨声淡出" "1.6")
    (list "move" "move_up" "smithy")
    (list "assert-map" "smithy")
    (list "assert-ambience" "rain" "off")

    (list "note" "走到老王面前按 E：对话开/关与打字音" "2.0")
    (list "walk" "smith-stand")
    (list "press" "E")
    (list "wait" "0.6")
    (list "assert-audio" "dialog-open" "1")
    (list "topic" "quest")
    (list "wait" "0.6")
    (list "assert-audio" "type" "1")
    (list "press" "E")
    (list "wait" "0.6")
    (list "assert-audio" "dialog-close" "1")

    (list "note" "出门回村：雨声恢复" "1.6")
    (list "walk" "door")
    (list "move" "move_down" "village")
    (list "assert-map" "village")
    (list "assert-ambience" "rain" "on")
    (list "gm" "speed 1")
    (list "note" "验收完成：脚步 / 雨声 / 对话音效都接上了" "2.0")))
