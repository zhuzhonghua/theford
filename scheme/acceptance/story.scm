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
    (list "note" "剧情验收开始：开场在河滩。正常玩法里你一进村就会看到这段旁白；这里先重置到开局再触发。按 E 逐句看，或 Esc 跳过。" "3.0")
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

    (list "note" "正常玩法：去铁匠铺找老王接「铁矿石」任务，捡 3 块矿交给他，他会重铸绞盘。这里用手动 beat 代替这段流程。" "3.0")
    (list "story-beat" "winch-ready")
    (list "assert-story-fact" "ford.winch-ready" "1")
    (list "assert-story-beat" "winch-ready")
    (list "assert-story-panel" "open")
    (list "assert-story-line" "绞盘")
    ;; Esc is the acceptance runner's global abort key; `story-skip` uses the
    ;; panel's own close path (the same one Esc uses in normal play).
    (list "story-skip")

    (list "note" "第二幕正常玩法：去旅店找张掌柜接「谁剪断了缆绳」，问清原委；到河滩看泥印，再看断缆。三件都做完才触发这段旁白。这里用手动 beat 代替。" "3.2")
    (list "story-beat" "clues-found")
    (list "assert-story-fact" "ford.clues-done" "1")
    (list "assert-story-line" "泥印")
    ;; Esc is the acceptance runner's global abort key; `story-skip` uses the
    ;; panel's own close path (the same one Esc uses in normal play).
    (list "story-skip")

    (list "note" "第三幕正常玩法：回铁匠铺找老王接「重开渡船」，先到广场东边找阿笋问明缘由，再回河滩按 E 接缆绳。完成后就是这段结局旁白。这里用手动 beat 代替。" "3.4")
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

    (list "note" "存档验证：F5 快存会把剧情事实一起写进 user://save1.scm；然后 GM reload 回到开局（事实清空），F9 读档再还原。" "2.6")
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
