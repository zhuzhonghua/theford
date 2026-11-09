;; quests.scm — quest definitions (data only): objectives + stages.
;;
;; A quest is an alist of:
;;   title        display name
;;   giver        npc id who gives the quest
;;   objectives   (id -> (text type need)) count objectives
;;   stages       (n -> stage-alist) ordered progression steps
;;
;; Each stage is an alist of:
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
;; The engine in quest.scm reads this data; adding a quest needs no code.

(define *quests*
  (list
    (cons "smith-ore"
      (list
        (cons 'title "老王的铁矿石")
        (cons 'giver "smith")
        (cons 'objectives
          (list
            (cons 'ore
              (list (cons 'text "铁矿石")
                    (cons 'type "item/material/ore")
                    (cons 'need 3)))))
        (cons 'stages
          (list
            (cons 10
              (list
                (cons 'label "offered")
                (cons 'greet "老王：来了？坐。炉火不等人，有什么话快说。")
                (cons 'quest-text "任务：未接（找铁匠老王聊聊）")
                (cons 'say-reject "活儿还没接呢，先把矿石找来再说。")
                (cons 'on-accept 20)
                (cons 'topics
                  (list (cons 'greet "打个招呼")
                        (cons 'village "聊聊村子")
                        (cons 'work "问问活计")
                        (cons 'quest "接任务")))))
            (cons 20
              (list
                (cons 'label "accepted")
                (cons 'greet "老王：矿石找着了没？河边滩上冲下来的石头里看好料。")
                (cons 'quest-text "任务：给老王找铁矿石（已交 {delivered} / {need}，背上还有 {carried} 块）")
                (cons 'objective 'ore)
                (cons 'say-reject "这可不行，先把矿石找来。")
                (cons 'topics-carry
                  (list (cons 'greet "打个招呼")
                        (cons 'village "聊聊村子")
                        (cons 'work "问问活计")
                        (cons 'give "交矿石（背上 {carried} 块）")))
                (cons 'topics-empty
                  (list (cons 'greet "打个招呼")
                        (cons 'village "聊聊村子")
                        (cons 'work "问问活计")
                        (cons 'quest "聊聊进度")))
                (cons 'say "好嘞！三块铁矿石，河边滩上冲下来的石头里看好料。找着了拿来我这儿。")
                (cons 'on-give-complete 100)))
            (cons 100
              (list
                (cons 'label "completed")
                (cons 'greet "老王：哈哈，成事之人。到屋里坐，我去给你拿剑。")
                (cons 'quest-text "任务：完成！老王送了你一把铁剑。")
                (cons 'say-reject "矿石早收齐了，剑不是已经给你了吗？")
                (cons 'topics
                  (list (cons 'greet "打个招呼")
                        (cons 'village "聊聊村子")
                        (cons 'work "问问活计")))
                (cons 'say "得了！矿石齐了，剑也成了。给你——往后就是渡口村的人了。")
                (cons 'take (list (cons 'type "item/material/ore") (cons 'count 3)))
                (cons 'reward (list (cons 'items (list (cons 'type "item/weapon/iron-sword") (cons 'count 1)))))
                (cons 'complete #t)))))))))
