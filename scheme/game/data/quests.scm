;; quests.scm — quest definitions (data only): objectives + stages.
;;
;; A quest is a table of:
;;   title        display name
;;   giver        npc id who gives the quest
;;   objectives   (id -> table of text/type/need) count objectives
;;   stages       (n -> stage table) ordered progression steps
;;
;; Each stage is a table of:
;;   label        human-readable state name
;;   greet        npc greeting line in this stage
;;   quest-text   HUD quest description (may use {delivered}/{carried}/{need})
;;   topics       topic menu for this stage ((key . label) ...)
;;   say          scripted line when the stage is entered
;;   objective    objective id tracked in this stage
;;   take         (type count) items removed from the player on entry
;;   reward       (items ((type count) ...)) items given on entry
;;   complete     #t when this stage finishes the quest
;;   on-accept    next stage number when the player accepts
;;   on-give-complete  next stage number when give() delivers enough
;;
;; Topic menus stay ordered alists on purpose: the HUD renders them in data
;; order, and hash tables have no order.
;;
;; The engine in quest.scm reads this data; adding a quest needs no code.
;;
;; Data DSL: `table` (util.scm).

(require "game.util")

(define *quests*
  (table
    (smith-ore
      (title = "老王的铁矿石")
      (giver = "smith")
      (objectives = (table
                      (ore
                        (text = "铁矿石")
                        (type = "item/material/ore")
                        (need = 3))))
      (stages = (table
                  (10
                    (label = "offered")
                    (greet = "老王：来了？坐。炉火不等人，有什么话快说。")
                    (quest-text = "任务：未接（找铁匠老王聊聊）")
                    (say-reject = "活儿还没接呢，先把矿石找来再说。")
                    (on-accept = 20)
                    (topics = '((greet . "打个招呼")
                                (village . "聊聊村子")
                                (work . "问问活计")
                                (quest . "接任务"))))
                  (20
                    (label = "accepted")
                    (greet = "老王：矿石找着了没？河边滩上冲下来的石头里看好料。")
                    (quest-text = "任务：给老王找铁矿石（已交 {delivered} / {need}，背上还有 {carried} 块）")
                    (objective = 'ore)
                    (say-reject = "这可不行，先把矿石找来。")
                    (topics-carry = '((greet . "打个招呼")
                                      (village . "聊聊村子")
                                      (work . "问问活计")
                                      (give . "交矿石（背上 {carried} 块）")))
                    (topics-empty = '((greet . "打个招呼")
                                      (village . "聊聊村子")
                                      (work . "问问活计")
                                      (quest . "聊聊进度")))
                    (say = "好嘞！三块铁矿石，河边滩上冲下来的石头里看好料。找着了拿来我这儿。")
                    (on-give-complete = 100))
                  (100
                    (label = "completed")
                    (greet = "老王：哈哈，成事之人。到屋里坐，我去给你拿剑。")
                    (quest-text = "任务：完成！老王送了你一把铁剑。")
                    (say-reject = "矿石早收齐了，剑不是已经给你了吗？")
                    (topics = '((greet . "打个招呼")
                                (village . "聊聊村子")
                                (work . "问问活计")))
                    (say = "得了！矿石齐了，剑也成了。给你——往后就是渡口村的人了。")
                    (take = (table
                              (type = "item/material/ore")
                              (count = 3)))
                    (reward = (table
                                (items = (table
                                           (type = "item/weapon/iron-sword")
                                           (count = 1)))))
                    (complete = #t)))))))
