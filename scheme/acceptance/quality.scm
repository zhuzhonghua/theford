;;; Phase 10.4 验收：AI 档位（quality）。
;;; GM 中输入：load quality
;;;
;;; 没有 off 档：GGUF 随包分发且启动失败会阻止进入游戏。三档只改生成预算与
;;; learned 缓存的 tier 规则：高档答案服务低档，低档答案不服务高档。
;;; 无头运行：THEFORD_ACCEPTANCE=quality THEFORD_ACCEPTANCE_QUIT=1

(define (acceptance:steps)
  (list
    (list "note" "AI 档位验收：先确认启动档位，再用 low/medium/high 走完整条 tier 缓存链" "3.0")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "assert-map" "village")
    (list "assert-start-ai-quality")

    (list "note" "low 档：新话题由模型生成（64 tok 预算）" "2.4")
    (list "gm" "quality low")
    (list "assert-ai-quality" "low")
    (list "walk" "apothecary-stand")
    (list "press" "E")
    (list "wait" "0.4")
    (list "topic" "village")
    (list "wait" "2.4")
    (list "assert-turn-source" "llm")

    (list "note" "再问一次：learned 缓存命中，不再推理" "2.4")
    (list "topic" "village")
    (list "wait" "1.2")
    (list "assert-turn-source" "cache")

    (list "note" "切 medium：low 的答案不服务中档，必须重新生成" "2.8")
    (list "gm" "quality medium")
    (list "assert-ai-quality" "medium")
    (list "topic" "village")
    (list "wait" "2.4")
    (list "assert-turn-source" "llm")

    (list "note" "medium 再问：缓存命中" "2.4")
    (list "topic" "village")
    (list "wait" "1.2")
    (list "assert-turn-source" "cache")

    (list "note" "切 high：medium 的答案不服务高档，必须重新生成" "2.8")
    (list "gm" "quality high")
    (list "assert-ai-quality" "high")
    (list "topic" "village")
    (list "wait" "2.8")
    (list "assert-turn-source" "llm")

    (list "note" "切回 low：高档答案服务低档，直接命中缓存" "2.4")
    (list "gm" "quality low")
    (list "assert-ai-quality" "low")
    (list "topic" "village")
    (list "wait" "1.2")
    (list "assert-turn-source" "cache")

    (list "note" "换个没缓存的话题 work：low 档确实会生成" "2.4")
    (list "topic" "work")
    (list "wait" "2.2")
    (list "assert-turn-source" "llm")

    (list "note" "低档生成的答案不服务中档：切回 medium 再问 work 会重新生成" "2.6")
    (list "gm" "quality medium")
    (list "assert-ai-quality" "medium")
    (list "topic" "work")
    (list "wait" "2.4")
    (list "assert-turn-source" "llm")
    (list "close-dialog")

    (list "gm" "speed 1")
    (list "note" "验收完成：三档切换与 tier 缓存规则都对" "2.4")))
