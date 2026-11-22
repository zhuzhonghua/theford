;;; Phase 7 验收（7.5）：村民看见史莱姆 nearby 会逃开。
;;; GM 中输入：load flee
;;;
;;; GM 只负责把一只史莱姆“引到”张掌柜身旁（等同玩家把它遛过去），
;;; 接下来村民自己发现威胁、自己跑开，脚本只观察距离变大。

(define (acceptance:steps)
  (list
    (list "note" "Phase 7：把张掌柜安排在看店的位置，再把史莱姆引到他旁边" "2.8")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "assert-map" "village")
    (list "gm" "npc innkeeper village:inn keeping")
    (list "wait" "1.5")
    (list "note" "史莱姆贴到掌柜身边了；看他自己往远处跑" "2.0")
    (list "gm" "slime innkeeper")
    (list "wait" "0.4")
    (list "assert-npc-from-creature" "innkeeper" "20")
    (list "note" "留出几秒让逃跑路径走完" "2.0")
    (list "wait" "2.6")
    (list "assert-npc-from-creature" "innkeeper" "45")
    (list "gm" "speed 1")
    (list "note" "验收完成：威胁逃跑通过" "2.4")))
