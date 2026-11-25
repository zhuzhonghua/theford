;; story-chain.scm — play the three-act quest chain end to end.
;;
;; The story subsystem acceptance fires beats manually for the later acts; this
;; one walks the actual quest links: 矿石 → 张掌柜的线索 → 老王的渡船, and
;; asserts state/xp from the same Scheme views the HUD reads. GM `give ore 3`
;; only skips the ore pick-up (already covered by `quests`); every interaction
;; below uses the same walk / E / topic path as a player.

(define (acceptance:steps)
  (list
    (list "note" "剧情链验收：先把老王的第一幕任务做完，拿到绞盘剧情" "2.4")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "walk" "smithy-door")
    (list "move" "move_up" "smithy")
    (list "assert-map" "smithy")
    (list "wait" "0.4")
    (list "walk" "smith-stand")
    (list "press" "E")
    (list "topic" "quest")
    (list "assert-quest" "smith-ore" "accepted")
    (list "press" "E")
    (list "gm" "give ore 3")
    (list "press" "E")
    (list "topic" "give")
    (list "assert-quest" "smith-ore" "completed")
    (list "assert-xp" "30")
    (list "press" "E") (list "press" "E") (list "press" "E")

    (list "note" "第二幕：张掌柜的线索——问原委、看泥印、看断缆" "2.4")
    (list "walk" "door")
    (list "move" "move_down" "village")
    (list "assert-map" "village")
    (list "wait" "0.4")
    ;; The innkeeper stands on the `inn` anchor itself; arrive at the adjacent
    ;; yard marker instead (still well inside E range).
    (list "walk" "inn-yard")
    (list "press" "E")
    (list "topic" "quest")
    (list "assert-quest" "clues" "accepted")
    (list "press" "E")
    (list "press" "E")
    (list "topic" "quest")
    (list "press" "E") (list "press" "E") (list "press" "E")
    (list "walk" "rope-end")
    ;; Extra E presses close a dialogue if E fell through to a nearby villager
    ;; instead of the clue; a real player would just press E again to leave it.
    (list "press" "E") (list "press" "E") (list "press" "E")
    (list "walk" "river-mud")
    (list "press" "E") (list "press" "E") (list "press" "E")
    ;; The second target only becomes the active objective after the first
    ;; one is delivered, so the rope needs a second visit.
    (list "walk" "rope-end")
    (list "press" "E") (list "press" "E") (list "press" "E")
    (list "assert-quest" "clues" "completed")
    (list "assert-xp" "70")

    (list "note" "第三幕：老王接渡船任务，问阿笋，接缆绳" "2.4")
    (list "walk" "smithy-door")
    (list "move" "move_up" "smithy")
    (list "assert-map" "smithy")
    (list "wait" "0.4")
    (list "walk" "smith-stand")
    (list "press" "E")
    (list "topic" "quest")
    (list "assert-quest" "ferry" "accepted")
    (list "press" "E")
    (list "walk" "door")
    (list "move" "move_down" "village")
    (list "assert-map" "village")
    (list "walk" "axun-spot")
    (list "press" "E")
    (list "close-dialog")
    (list "walk" "winch")
    (list "press" "E")
    (list "assert-quest" "ferry" "completed")
    (list "assert-xp" "120")
    (list "note" "验收完成：三幕任务链可以从头走到渡船重开" "2.4")))
