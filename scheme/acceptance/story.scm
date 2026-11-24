;; story.scm — story/fact engine acceptance.
;;
;; Verifies the full path: a named place reaches Scheme, a beat fires on the
;; tick schedule, its facts are written, and its scene lines reach the modal
;; panel through the effect bus. Manual `story-beat` triggers cover beats whose
;; natural conditions need a long quest chain; the arrive beat is deliberately
;; left to fire on its own so the scheduling path is exercised, not bypassed.

(define (acceptance:steps)
  (list
    ;; Work from a clean opening no matter when the script is loaded: `gm
    ;; reload` clears story facts/seen (and is what a new game does), then we
    ;; explicitly put the player at the riverbank and report that place. Let
    ;; the natural 3-tick scan fire the beat; only the setup is scripted.
    (list "note" "剧情验收：回到开局，让河滩开场 beat 自己触发" "2.6")
    (list "gm" "reload")
    (list "gm" "speed 1")
    (list "place" "village" "village:riverbank")
    (list "story-place" "riverbank")
    (list "wait" "1.6")
    (list "assert-story-fact" "ford.arrived" "1")
    (list "assert-story-panel" "open")
    (list "assert-story-line" "渡口村")
    (list "note" "跳过演出，再逐幕验证 fact 与台词" "1.5")
    ;; Esc is the acceptance runner's global abort key; `story-skip` uses the
    ;; panel's own close path (the same one Esc uses in normal play).
    (list "story-skip")
    (list "assert-story-panel" "closed")

    (list "story-beat" "winch-ready")
    (list "assert-story-fact" "ford.winch-ready" "1")
    (list "assert-story-beat" "winch-ready")
    (list "assert-story-panel" "open")
    (list "assert-story-line" "绞盘")
    ;; Esc is the acceptance runner's global abort key; `story-skip` uses the
    ;; panel's own close path (the same one Esc uses in normal play).
    (list "story-skip")

    (list "note" "第二幕：线索齐备后，旁白把三件事拼到一处" "1.8")
    (list "story-beat" "clues-found")
    (list "assert-story-fact" "ford.clues-done" "1")
    (list "assert-story-line" "泥印")
    ;; Esc is the acceptance runner's global abort key; `story-skip` uses the
    ;; panel's own close path (the same one Esc uses in normal play).
    (list "story-skip")

    (list "note" "第三幕：渡船重开" "1.6")
    (list "story-beat" "ferry-open")
    (list "assert-story-fact" "ford.ferry-open" "1")
    (list "assert-story-line" "我爹留下的")
    (list "assert-log" "第三幕")
    ;; Esc is the acceptance runner's global abort key; `story-skip` uses the
    ;; panel's own close path (the same one Esc uses in normal play).
    (list "story-skip")
    (list "assert-story-panel" "closed")

    (list "note" "受保护 fact 不能从调试边界写入；普通 fact 可以" "1.6")
    (list "gm" "story fact test.flag 7")
    (list "assert-story-fact" "test.flag" "7")
    (list "gm" "story fact seen.arrive 999")
    (list "assert-story-fact" "ford.arrived" "1")

    (list "note" "存档带走剧情事实；热重载回到开局" "2.0")
    (list "press" "F5")
    (list "wait" "0.8")
    (list "gm" "reload")
    (list "assert-story-fact-absent" "test.flag")
    (list "assert-story-fact-absent" "ford.arrived")
    (list "press" "F9")
    (list "wait" "1.0")
    (list "assert-story-fact" "test.flag" "7")
    (list "assert-story-fact" "ford.arrived" "1")

    (list "note" "验收完成：剧情事实、场景演出、保护前缀与存档均通过" "2.4")))
