;;; Phase 7 验收（7.1–7.3）：史莱姆刷出、咬人掉血、斧头三下击杀并掉落凝胶。
;;; GM 中输入：load combat
;;;
;;; 回放按“人玩”的节奏：先用 GM 准备 Starting State（等同 give/equip），
;;; 然后走到史莱姆旁挨一口，再抡斧头反击。GM 只做时间/物品这类确定性设置，
;;; 走位、挨咬和挥砍都走正常游戏路径。

(define (acceptance:steps)
  (list
    (list "note" "Phase 7：河边刷了两只史莱姆，先看看它们和玩家的生命" "2.8")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "assert-map" "village")
    (list "assert-creature-count" "2")
    (list "assert-hp" "10")
    (list "note" "开箱拿斧太远，这里用 GM 直接给一把并装备（等同背包里点一下）" "2.2")
    (list "gm" "give axe 1")
    (list "gm" "equip axe")
    (list "assert-held" "item/tool/axe")
    (list "note" "走到史莱姆旁，站着别动，让它咬一口" "2.0")
    (list "walk-to-creature")
    (list "wait" "3.2")
    (list "assert-hp-at-most" "9")
    (list "assert-log" "史莱姆咬了你一口")
    (list "note" "斧头 power 3，史莱姆 hp 8：第一斧后剩 5" "2.0")
    (list "attack")
    (list "assert-last-entity-type" "actor/creature/slime")
    (list "assert-last-entity-hp" "5")
    (list "note" "第二斧：剩 2 点生命" "1.6")
    (list "attack")
    (list "assert-last-entity-hp" "2")
    (list "note" "第三斧：史莱姆化为凝胶，掉在地上一会儿会被磁吸进背包" "2.2")
    (list "attack")
    (list "assert-creature-count" "1")
    (list "assert-bag" "item/material/gel" "1")
    (list "assert-log" "史莱姆化作一滩凝胶")
    (list "gm" "heal")
    (list "assert-hp" "10")
    (list "gm" "speed 1")
    (list "note" "验收完成：刷怪、咬人、三斧击杀、掉落拾取都通过" "2.4")))
