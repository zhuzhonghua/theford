;;; 回归验收：热重载（F5 / GM reload）要连当前场景一起回到开局。
;;; GM 中输入：load reload-scene
;;;
;;; 砍倒村口那棵树留下树桩，再 reload。之前只重置 Scheme 的时钟/任务/背包，
;;; 树桩和 Scheme 里的 stump 状态都留在原地，得进屋再出来才恢复。现在 reload
;;; 会重建当前地图并重新注册场景实体：树、格子和掉落物都回到入场状态，
;;; 玩家仍站在原处。断言同时查 Scheme 视图与 Godot 侧的精灵状态。
;;; 脚本不还原场景：跑完后玩家仍在树旁，树是完好的。

(define (acceptance:steps)
  (list
    (list "note" "热重载回归：先砍倒一棵树，再按 F5 看它会不会变回树" "2.6")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "assert-map" "village")
    (list "note" "沿村道往北进门，去铁匠铺箱子里拿斧头" "1.8")
    (list "walk" "smithy-door")
    (list "move" "move_up" "smithy")
    (list "assert-map" "smithy")
    (list "wait" "0.4")
    (list "walk-interact")
    (list "assert-bag" "item/tool/axe" "1")
    (list "note" "拿着斧头回村口" "1.6")
    (list "walk" "door")
    (list "move" "move_down" "village")
    (list "assert-map" "village")
    (list "wait" "0.4")
    (list "note" "走到树旁砍两下：倒下后留下树桩" "2.0")
    (list "walk-use")
    (list "use")
    (list "wait" "0.8")
    (list "assert-last-entity-type" "fixture/stump")
    (list "assert-last-entity-hp" "0")
    (list "assert-scene-entity" "fixture/stump")
    (list "note" "现在热重载：时钟、任务和背包回开局，当前场景也要重建" "2.6")
    (list "gm" "reload")
    (list "assert-map" "village")
    (list "assert-last-entity-type" "fixture/tree")
    (list "assert-last-entity-hp" "6")
    (list "assert-scene-entity" "fixture/tree")
    (list "assert-bag" "item/tool/axe" "0")
    (list "assert-near-entity" "last")
    (list "note" "树桩变回完整的树，玩家没被挪走，背包也空了" "2.2")
    (list "gm" "speed 1")
    (list "note" "验收完成：reload 后不必进屋再出来" "2.4")))
