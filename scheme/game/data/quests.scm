;; quests.scm — quest definitions (data only): objectives + stages.
;;
;; A quest is a table of:
;;   title        display name
;;   giver        npc id who gives the quest
;;   start        stage number the quest starts at
;;   pack-item    what the tracked objective is called in prompt text
;;   accept-text  player line used when accepting the quest
;;   give-text    player line used when handing items in
;;   objectives   (id -> table of text/type/need) count objectives
;;   stages       (n -> stage table) ordered progression steps
;;   hints        verdict status -> LLM steering line
;;   reasons      verdict key -> mechanism trace text ({n}/{delivered}/{need})
;;
;; Each stage is a table of:
;;   state        state symbol the engine switches to (not-offered/accepted/completed)
;;   greet        npc greeting line in this stage
;;   quest-text   HUD quest description (may use {delivered}/{carried}/{need})
;;   topics       topic menu for this stage ((key . label) ...)
;;   say          scripted line when the stage is entered
;;   say-reject   scripted line when the stage refuses the player
;;   objective    objective id tracked in this stage
;;   take         (type count) items removed from the player on entry
;;   reward       (items ((type count) ...)) items given on entry
;;   complete     #t when this stage finishes the quest
;;   on-accept    next stage number when the player accepts
;;   on-give-complete  next stage number when give() delivers enough
;;
;; Topic menus stay ordered alists on purpose: the HUD renders them in data
;; order, and hash tables have no order. They start from the shared
;; *default-topics* (data/dialogue.scm) and append the stage's own entries.
;;
;; The engine in quest.scm reads this data; adding a quest needs no code.
;;
;; Data DSL: `table` (util.scm).

(require "game.util")
(require "game.data.dialogue")

(define *quests*
  (table
    (smith-ore
      (title = "老王的铁矿石")
      (giver = 'smith)
      (start = 10)
      (pack-item = "铁矿石")
      (accept-text = "我想接下你的任务。")
      (give-text = "给你，矿石都在这儿。")
      (hints = (table
                 (accepted = "老王的请求得到了满足，简短回应，语气高兴。")
                 (rejected = "老王必须拒绝，例如：不行，你还没接这活儿呢。")
                 (ignored = "只是闲聊，老王正常回应即可。")))
      (reasons = (table
                   (accept-ok = "玩家接受了任务")
                   (accept-dup = "任务已经接过")
                   (accept-done = "任务早已完成")
                   (give-empty = "玩家背上没有矿石")
                   (give-not-accepted = "任务还没接，不能收矿石")
                   (give-done = "任务已完成")
                   (give-partial = "收下 {n} 块矿石（{delivered} / {need}）")
                   (idle = "闲聊，不动状态")))
      (objectives = (table
                      (ore
                        (text = "铁矿石")
                        (type = "item/material/ore")
                        (need = 3))))
      (stages = (table
                  (10
                    (state = 'not-offered)
                    (greet = "老王：来了？坐。炉火不等人，有什么话快说。")
                    (quest-text = "任务：未接（找铁匠老王聊聊）")
                    (say-reject = "活儿还没接呢，先把矿石找来再说。")
                    (on-accept = 20)
                    (topics = (append *default-topics*
                                      '((quest . "接任务")))))
                  (20
                    (state = 'accepted)
                    (greet = "老王：矿石找着了没？河边滩上冲下来的石头里看好料。")
                    (quest-text = "任务：给老王找铁矿石（已交 {delivered} / {need}，背上还有 {carried} 块）")
                    (objective = 'ore)
                    (say-reject = "这可不行，先把矿石找来。")
                    (topics-carry = (append *default-topics*
                                            '((give . "交矿石（背上 {carried} 块）"))))
                    (topics-empty = (append *default-topics*
                                            '((quest . "聊聊进度"))))
                    (say = "好嘞！三块铁矿石，河边滩上冲下来的石头里看好料。找着了拿来我这儿。")
                    (on-give-complete = 100))
                  (100
                    (state = 'completed)
                    (greet = "老王：哈哈，成事之人。到屋里坐，我去给你拿剑。")
                    (quest-text = "任务：完成！老王送了你一把铁剑。")
                    (say-reject = "矿石早收齐了，剑不是已经给你了吗？")
                    (topics = *default-topics*)
                    (say = "得了！矿石齐了，剑也成了。给你——往后就是渡口村的人了。")
                    (take = (table
                              (type = "item/material/ore")
                              (count = 3)))
                    (reward = (table
                                (items = (table
                                           (type = "item/weapon/iron-sword")
                                           (count = 1)))))
                    (complete = #t)))))))
