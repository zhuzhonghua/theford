;; story.scm — story beats, facts and invariants (data only).
;;
;; A beat is a row in *steps* keyed by its id. *story-order* is the playback
;; order: when several beats become eligible on one tick, the first one wins.
;; Order is a list, not a hash table, because hash tables have no stable order.
;;
;; Beat fields:
;;   when    conditions (all must hold); omitted = always
;;   script  scene commands; when present it takes control of the presentation
;;   say     a single narration line used when there is no `script`
;;   facts   facts written when the beat plays
;;   repeat  when #t the beat may play once per in-game day (default #f)
;;   manual  when #t it only fires from a GM/dev trigger (default #f)
;;
;; Supported `when` keys (all ANDed):
;;   map       current map id, a string
;;   place     nearest named anchor the player is at, a string
;;   day       minimum in-game day, a number
;;   hour      (from to) hour window; to <= from wraps midnight
;;   weather   symbol or list of symbols
;;   facts     ((fact-id expected) ...) compared with story:cmp
;;   quest     ((quest-id state-symbol) ...) e.g. (smith-ore completed)
;;   carrying  list of item type prefixes in the bag
;;   after     beat id that must already have played
;;
;; Scene commands are flat tuples consumed by the effect bus, e.g.
;;   ("scene" "第一幕 · 修船料" (("旁白" "……") ("旁白" "……")))
;; Scheme decides the beat and writes its facts; Godot presents the lines.
;;
;; Facts live in a single pseudo-entity's property bag (story.scm's *facts*).
;; Prefixes in *protected-facts* are reserved for the story engine: GM/debug
;; writes refuse them, so a patch cannot redefine `seen.*` or `ford.*`.
;;
;; Data DSL: `table` (util.scm).

(require "game.util")

(define *protected-facts*
  '("seen." "step." "invalid." "topic." "ford."))

;; Human-facing labels used to fold facts into the LLM prompt (Phase 10.5).
(define *story-labels*
  (table
    (ford.arrived = "抵达渡口")
    (ford.winch-ready = "绞盘重铸")
    (ford.clues-done = "线索齐备")
    (ford.axun-known = "问过阿笋")
    (ford.ferry-open = "渡船重开")))

(define *story-order*
  '(arrive winch-request winch-ready clues-offered clues-found
           axun-sighting ferry-ready ferry-open))

(define *steps*
  (table
    ;; ---- Act 1: 修船料 -------------------------------------------------------
    (arrive
      (when = '((map "village") (place "riverbank")))
      (facts = '((ford.arrived 1)))
      (script = '(("scene" "第一幕 · 修船料"
                    (("旁白" "你揣着那封信，站在渡口村的河滩上。河面空荡荡的——三天前，渡船的缆绳在夜里被人剪断了。")
                     ("旁白" "对岸的集市、药铺的供货，还有等着客人的旅店，都隔在一水之遥。")
                     ("旁白" "村里说铁匠老王正愁着修船的绞盘。先去问问他吧。")))))
      (say = "渡船断了三天，村子安静得只剩水声。"))

    (winch-request
      (when = '((after "arrive") (place "smithy-door")
                (quest ((smith-ore not-offered)))))
      (say = "炉火噼啪响。老王抬头看了你一眼，又低下头去——他像是想开口，又怕白说。"))

    (winch-ready
      (when = '((quest ((smith-ore completed)))))
      (facts = '((ford.winch-ready 1)))
      (script = '(("scene" "绞盘重铸"
                    (("老王" "得嘞，绞盘重打好了。剩下的活儿就是把缆绳接上。")
                     ("旁白" "老王把铁剑收回柜台，朝河滩的方向努了努嘴。")))))
      (say = "老王：绞盘成了，缆绳的事还得再打听打听。"))

    ;; ---- Act 2: 谁剪的 -------------------------------------------------------
    (clues-offered
      (when = '((facts ((ford.winch-ready 1))) (place "inn")
                (quest ((clues not-offered)))))
      (say = "张掌柜隔着柜台叹气：客人过不来，屋子空了一半。他似乎知道点河滩上的事。"))

    (clues-found
      (when = '((quest ((clues completed)))))
      (facts = '((ford.clues-done 1)))
      (script = '(("scene" "第二幕 · 谁剪的"
                    (("旁白" "河滩的泥印、断口整齐的缆绳，还有村口少年阿笋那躲闪的眼神——三件事慢慢拼到了一处。")
                     ("旁白" "缆绳不是被水磨断的。可谁会剪断它？")))))
      (say = "线索齐了，可还差一个开口的人。"))

    (axun-sighting
      (when = '((facts ((ford.clues-done 1))) (place "village-square")
                (quest ((ferry not-offered)))))
      (say = "阿笋蹲在广场边，手里攥着一段旧绳头。看见你来，他把绳头往怀里一塞。"))

    ;; ---- Act 3: 揭晓与渡河 ---------------------------------------------------
    (ferry-ready
      (when = '((facts ((ford.clues-done 1))) (place "smithy-door")
                (quest ((ferry not-offered)))))
      (say = "老王把新绞盘搬到门口：只要再有人把缆绳接好，渡船就能下水。"))

    (ferry-open
      (when = '((quest ((ferry completed)))))
      (facts = '((ford.ferry-open 1)))
      (script = '(("scene" "第三幕 · 重开渡河"
                    (("阿笋" "……那船是我爹留下的。我怕你们把它拖走。")
                     ("老王" "哼，谁要拖走它？修好了，还是你爹的船。")
                     ("旁白" "第一班渡船在晨雾里离岸。你把信送到了对岸，回头看见渡口村的人都在挥手。")))))
      (say = "渡船重开，信也送到了。"))))

;; A stuck-state detector: after the player has arrived, if no quest has been
;; accepted by the second day, nudge once. `holds` uses the same fact/quest
;; comparison vocabulary as a beat's `when`.
(define *invariants*
  (table
    (stuck-nudge
      (when = '((day 2) (facts ((ford.arrived 1)))))
      (holds = '((any-quest-accepted 1)))
      (fallback = "村民们各有各的难处，去跟他们聊聊，问问有什么能帮上忙的。"))))
