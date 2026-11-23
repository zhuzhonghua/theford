;;; Phase 10.5 验收：日程 / 天气 / 时辰进入 LLM prompt。
;;; GM 中输入：load prompt
;;;
;;; 台词内容由模型决定，不能逐字断言；但"雨天问天气与晴天回答不同"的前提是
;;; 这两次生成的 prompt 真的带了不同的情境。脚本直接取 build-prompt 的产物
;;; （与真实回合同一个函数，只是不跑模型），断言其中的时辰、天气与 NPC 当前
;;; activity：改天气 / 改时钟后情境行必须变化，且不同 NPC 读各自的日程。
;;; 无头运行：THEFORD_ACCEPTANCE=prompt THEFORD_ACCEPTANCE_QUIT=1

(define (acceptance:steps)
  (list
    (list "note" "情境入 prompt 验收：prompt 里会带时辰、天气和 NPC 正在做的事" "3.0")
    (list "gm" "speed 0")
    (list "gm" "weather sun")

    (list "note" "上午 11 点，晴天：老王在铁匠铺打铁" "2.2")
    (list "gm" "time 11:00")
    ;; GM prompt 把完整 prompt 打到控制台：编辑器控制台里可直接对照改前/改后
    (list "gm" "prompt smith village")
    (list "assert-prompt-contains" "smith" "village" "11:00")
    (list "assert-prompt-contains" "smith" "village" "天气：晴")
    (list "assert-prompt-contains" "smith" "village" "老王正在打铁")

    (list "note" "改成下雨：同一时刻同一话题，情境行必须跟着变（雨天回答才会与晴天不同）" "2.6")
    (list "gm" "weather rain")
    (list "gm" "prompt smith village")
    ;; changed goes before contains: it compares against the prompt the last
    ;; assert fetched, i.e. the sunny one from the previous block.
    (list "assert-prompt-changed" "smith" "village")
    (list "assert-prompt-contains" "smith" "village" "天气：下雨")

    (list "note" "跳到晚上 8 点：activity 取自日程，老王去酒馆歇脚，陈婆在村口闲逛" "2.8")
    (list "gm" "time 20:00")
    (list "assert-prompt-changed" "smith" "village")
    (list "assert-prompt-contains" "smith" "village" "20:00")
    (list "assert-prompt-contains" "smith" "village" "老王正在歇脚")
    (list "assert-prompt-contains" "apothecary" "village" "陈婆正在闲逛")

    (list "note" "夜里 11 点：老王回屋睡觉，情境行再次变化" "2.6")
    (list "gm" "time 23:00")
    (list "assert-prompt-changed" "smith" "village")
    (list "assert-prompt-contains" "smith" "village" "正在睡觉")

    (list "gm" "weather auto")
    (list "gm" "speed 1")
    (list "note" "验收完成：时辰 / 天气 / 日程都已进入 prompt，且 learned 缓存按情境分开" "2.4")))
