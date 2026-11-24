;; quests.scm — quest definitions (data only): objectives + stages + rewards.
;;
;; *quest-order* decides HUD/log order and is the list of quests the engine
;; tracks. Every quest id below must appear in it.
;;
;; A quest is a table of:
;;   title        display name
;;   giver        npc id who gives the quest
;;   start        stage number the quest starts at
;;   pack-item    what the tracked objective is called in prompt text
;;   accept-text  player line used when accepting the quest
;;   give-text    player line used when handing items in
;;   objective-order  objective ids in HUD order
;;   objectives   (id -> table of text/kind/type/need)
;;                kind = count (deliver items) | talk (talk to giver) |
;;                       target (interact with a world object)
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
;;   reward       (xp n items (type count)) granted on entry
;;   complete     #t when this stage finishes the quest
;;   on-accept / on-give-complete / on-talk-complete / on-target-complete
;;                next stage number when that intent finishes
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

(define *quest-order* '(smith-ore apothecary-herbs clues ferry))

(define *quests*
  (table
    (smith-ore
      (title = "老王的铁矿石")
      (giver = 'smith)
      (start = 10)
      (pack-item = "铁矿石")
      (accept-text = "我想接下你的任务。")
      (give-text = "给你，矿石都在这儿。")
      (objective-order = '(ore))
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
                        (kind = 'count)
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
                                (xp = 30)
                                (items = (table
                                           (type = "item/weapon/iron-sword")
                                           (count = 1)))))
                    (complete = #t)))))

    (apothecary-herbs
      (title = "陈婆的草药")
      (giver = 'apothecary)
      (start = 10)
      (pack-item = "草药")
      (accept-text = "陈婆，你慢慢说，我去给你找。")
      (give-text = "陈婆，草药我采回来了。")
      (objective-order = '(ask herb))
      (hints = (table
                 (accepted = "陈婆的托付有了着落，简短回应，语气温和。")
                 (rejected = "陈婆必须拒绝，例如：哎，这事你还没答应呢。")
                 (ignored = "只是闲聊，陈婆正常回应即可。")))
      (reasons = (table
                   (accept-ok = "玩家答应帮陈婆采药")
                   (accept-dup = "采药的事已经答应过了")
                   (accept-done = "草药早就交齐了")
                   (talk-progress = "问清了陈婆要什么草药")
                   (target-progress = "查看了陈婆说的药圃")
                   (give-empty = "玩家背上没有草药")
                   (give-not-accepted = "还没答应陈婆，不能收草药")
                   (give-done = "草药已经交齐")
                   (give-partial = "收下 {n} 株草药（{delivered} / {need}）")
                   (idle = "闲聊，不动状态")))
      (objectives = (table
                      (ask
                        (text = "问问陈婆的难处")
                        (kind = 'talk)
                        (need = 1))
                      (herb
                        (text = "草药")
                        (kind = 'count)
                        (type = "item/material/herb")
                        (need = 5))))
      (stages = (table
                  (10
                    (state = 'not-offered)
                    (greet = "陈婆：外乡人，别急着走。我这腿脚啊，越发不中用了。")
                    (quest-text = "任务：未接（找陈婆聊聊）")
                    (say-reject = "咳，这事你还没答应呢。")
                    (on-accept = 20)
                    (topics = (append *default-topics*
                                      '((quest . "接任务")))))
                  (20
                    (state = 'accepted)
                    (greet = "陈婆：菜地边上那几丛绿叶子，就是我要的草药。")
                    (quest-text = "任务：帮陈婆采药（先问问她要什么）")
                    (objective = 'ask)
                    (say-reject = "先听我把话说完呀。")
                    (topics-empty = (append *default-topics*
                                            '((quest . "问问采药的事"))))
                    (say = "渡船一断，药铺的供货也断了。我那几味草药，还得去菜地边自己采。你要是顺路，帮我问问清楚？")
                    (on-talk-complete = 30))
                  (30
                    (state = 'accepted)
                    (greet = "陈婆：菜地边上那几丛绿叶子，采五株就够我熬几副药了。")
                    (quest-text = "任务：帮陈婆采草药（已交 {delivered} / {need}，背上还有 {carried} 株）")
                    (objective = 'herb)
                    (say-reject = "草药还没采齐呢，别急着交差。")
                    (topics-carry = (append *default-topics*
                                            '((give . "交草药（背上 {carried} 株）"))))
                    (topics-empty = (append *default-topics*
                                            '((quest . "聊聊进度"))))
                    (say = "就是菜地边那几丛，五株足够。河边潮气重，别踩滑了。")
                    (on-give-complete = 100))
                  (100
                    (state = 'completed)
                    (greet = "陈婆：药熬上了，你这孩子，比我家那小子还贴心。")
                    (quest-text = "任务：完成！陈婆留了你两份干粮。")
                    (say-reject = "草药早收下了，快去忙你的吧。")
                    (topics = *default-topics*)
                    (say = "好，好。这几份干粮你带着，路上垫垫肚子。")
                    (reward = (table
                                (xp = 20)
                                (items = (list
                                           (table (type = "item/food/meat") (count = 2))))))
                    (complete = #t)))))

    ;; ---- Act 2: 谁剪的（张掌柜）----------------------------------------------
    (clues
      (title = "谁剪断了缆绳")
      (giver = 'innkeeper)
      (start = 10)
      (pack-item = "线索")
      (accept-text = "我帮你问问河滩上到底出了什么事。")
      (give-text = "河滩的痕迹我都看过了。")
      (objective-order = '(ask mud rope))
      (hints = (table
                 (accepted = "张掌柜的线索有了着落，简短回应。")
                 (rejected = "张掌柜必须拒绝，例如：这事你还没答应帮忙呢。")
                 (ignored = "只是闲聊，张掌柜正常回应即可。")))
      (reasons = (table
                   (accept-ok = "玩家答应帮张掌柜打听渡船的事")
                   (accept-dup = "这事已经答应过了")
                   (accept-done = "线索已经查清了")
                   (talk-progress = "问清了客人过不来的原委")
                   (target-progress = "查看过河滩上的痕迹")
                   (idle = "闲聊，不动状态")))
      (objectives = (table
                      (ask
                        (text = "问问张掌柜客人为何过不来")
                        (kind = 'talk)
                        (need = 1))
                      (mud
                        (text = "查看河滩泥印")
                        (kind = 'target)
                        (target = "river-mud")
                        (need = 1))
                      (rope
                        (text = "查看断口整齐的缆绳")
                        (kind = 'target)
                        (target = "rope-end")
                        (need = 1))))
      (stages = (table
                  (10
                    (state = 'not-offered)
                    (greet = "张掌柜：客官住店？唉，渡船一断，屋里空了一半。")
                    (quest-text = "任务：未接（找张掌柜打听渡船的事）")
                    (say-reject = "这事你还没答应帮忙呢。")
                    (on-accept = 20)
                    (topics = (append *default-topics*
                                      '((quest . "接任务")))))
                  (20
                    (state = 'accepted)
                    (greet = "张掌柜：河滩上留有痕迹，你去瞧瞧，兴许能看出点门道。")
                    (quest-text = "任务：查查渡船断缆（先问清张掌柜的难处）")
                    (objective = 'ask)
                    (say-reject = "先听我把话说完呀。")
                    (topics-empty = (append *default-topics*
                                            '((quest . "问问渡船的事"))))
                    (say = "三天前夜里，河滩上有水声，可第二天谁都没见人。客人们过不来，我这店的灯火都省着点。")
                    (on-talk-complete = 30))
                  (30
                    (state = 'accepted)
                    (greet = "张掌柜：滩上的泥印还在，去看看吧。")
                    (quest-text = "任务：查看河滩泥印")
                    (objective = 'mud)
                    (say-reject = "泥印还没看呢。")
                    (topics-empty = (append *default-topics*
                                            '((quest . "聊聊线索"))))
                    (say = "河滩上有半串泥印，从水里上来，又折回村里。")
                    (on-target-complete = 40))
                  (40
                    (state = 'accepted)
                    (greet = "张掌柜：缆绳断口就在滩边那截木桩上。")
                    (quest-text = "任务：查看断口整齐的缆绳")
                    (objective = 'rope)
                    (say-reject = "缆绳的断口还没瞧清楚呢。")
                    (topics-empty = (append *default-topics*
                                            '((quest . "聊聊线索"))))
                    (say = "断口齐得不像磨断的，是有人用刀割的。")
                    (on-target-complete = 100))
                  (100
                    (state = 'completed)
                    (greet = "张掌柜：原来如此。那孩子……唉，去问问老王吧。")
                    (quest-text = "任务：完成！ clues 齐了，去问老王修船。")
                    (say-reject = "线索都查清了，快去忙吧。")
                    (topics = *default-topics*)
                    (say = "泥印、断缆，还有村口那孩子躲闪的样子——你心里大概有数了。去跟老王合计合计怎么修船吧。")
                    (reward = (table (xp = 40)))
                    (complete = #t)))))

    ;; ---- Act 3: 重开渡河（老王）----------------------------------------------
    (ferry
      (title = "重开渡船")
      (giver = 'smith)
      (start = 10)
      (pack-item = "缆绳")
      (accept-text = "交给我吧，我去跟阿笋谈谈。")
      (give-text = "缆绳接好了。")
      (objective-order = '(confront wire))
      (hints = (table
                 (accepted = "老王的渡船有了希望，简短回应。")
                 (rejected = "老王必须拒绝，例如：这事还没托付你呢。")
                 (ignored = "只是闲聊，老王正常回应即可。")))
      (reasons = (table
                   (accept-ok = "玩家答应帮忙重开渡船")
                   (accept-dup = "修船的事已经答应过了")
                   (accept-done = "渡船已经重开")
                   (target-progress = "渡船又近了一步")
                   (idle = "闲聊，不动状态")))
      (objectives = (table
                      (confront
                        (text = "找阿笋问明缘由")
                        (kind = 'target)
                        (target = "axun")
                        (need = 1))
                      (wire
                        (text = "接好绞盘上的缆绳")
                        (kind = 'target)
                        (target = "winch")
                        (need = 1))))
      (stages = (table
                  (10
                    (state = 'not-offered)
                    (greet = "老王：哼，缆绳的事查清楚了？那船总不能一直搁着。")
                    (quest-text = "任务：未接（找老王修船）")
                    (say-reject = "修船的事你还没答应帮忙呢。")
                    (on-accept = 20)
                    (topics = (append *default-topics*
                                      '((quest . "接任务")))))
                  (20
                    (state = 'accepted)
                    (greet = "老王：先去问问阿笋，那孩子心里有结。别吓着他。")
                    (quest-text = "任务：找阿笋问明缘由")
                    (objective = 'confront)
                    (say-reject = "先去跟阿笋说说话。")
                    (topics-empty = (append *default-topics*
                                            '((quest . "聊聊修船"))))
                    (say = "他那船是他爹留下的。剪缆绳，怕的是有人把船拖走。你去听听他怎么说。")
                    (on-target-complete = 30))
                  (30
                    (state = 'accepted)
                    (greet = "老王：绞盘在滩边，缆绳我留了一截。去接上吧。")
                    (quest-text = "任务：接好绞盘上的缆绳")
                    (objective = 'wire)
                    (say-reject = "缆绳还没接呢。")
                    (topics-empty = (append *default-topics*
                                            '((quest . "聊聊修船"))))
                    (say = "船还是那条船。修好了，谁也拖不走。")
                    (on-target-complete = 100))
                  (100
                    (state = 'completed)
                    (greet = "老王：第一班渡船明早就开。你那封信，也该送到了。")
                    (quest-text = "任务：完成！渡船重开，信送到了对岸。")
                    (say-reject = "渡船都开了，快去忙你的吧。")
                    (topics = *default-topics*)
                    (say = "得嘞，缆绳接好了。明早头一班渡船，我亲自撑。")
                    (reward = (table (xp = 50)))
                    (complete = #t)))))))
