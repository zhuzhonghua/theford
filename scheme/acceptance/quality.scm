;;; Phase 10.4 验收：AI 档位（quality）。
;;; GM 中输入：load quality
;;;
;;; 直接 F8 输入 load quality 即可，任何启动档位都能跑：先校验启动档位与
;;; THEFORD_AI_QUALITY 一致，再用 GM 主动切到 off，之后走完整条链：
;;;   预置台词 → 切 medium 生成 → 缓存命中 → high 重新生成（低档不服务高档）
;;;   → low 新话题按 64 tok 生成（低档答案不服务中档）→ low/off 回放高档缓存。
;;; 断言读 bridge 快照里的档位与上一轮台词来源，等同看机制 HUD 的那几行。
;;; 无头运行：THEFORD_ACCEPTANCE=quality THEFORD_ACCEPTANCE_QUIT=1
;;;           （也可加 THEFORD_AI_QUALITY=0 验证 off 启动路径）

(define (acceptance:steps)
  (list
    (list "note" "AI 档位验收：先确认启动档位来自 THEFORD_AI_QUALITY，再用 GM 切到 off 从零演示" "3.0")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "assert-map" "village")
    (list "assert-start-ai-quality")
    (list "gm" "quality off")
    (list "assert-ai-quality" "off")

    (list "note" "走到陈婆身边做一次普通闲聊（village 话题）：off 档不请求模型" "2.4")
    (list "walk" "apothecary-stand")
    (list "press" "E")
    (list "wait" "0.4")
    (list "topic" "village")
    (list "wait" "0.8")
    (list "assert-turn-source" "canned")

    (list "note" "切到 medium：模型可用（若以 off 启动，这一步会在逻辑线程按需加载），同一话题这次由 LLM 生成" "3.0")
    (list "gm" "quality medium")
    (list "assert-ai-quality" "medium")
    (list "topic" "village")
    (list "wait" "2.4")
    (list "assert-turn-source" "llm")

    (list "note" "再问一次：learned 缓存命中，不再推理" "2.4")
    (list "topic" "village")
    (list "wait" "1.2")
    (list "assert-turn-source" "cache")

    (list "note" "切到 high：medium 的答案不服务高档，必须重新生成" "2.6")
    (list "gm" "quality high")
    (list "assert-ai-quality" "high")
    (list "topic" "village")
    (list "wait" "2.8")
    (list "assert-turn-source" "llm")

    (list "note" "切到 low：高档答案服务低档，直接命中缓存" "2.4")
    (list "gm" "quality low")
    (list "assert-ai-quality" "low")
    (list "topic" "village")
    (list "wait" "1.2")
    (list "assert-turn-source" "cache")

    (list "note" "换个没缓存的话题：low 档确实会生成（64 tok 预算）" "2.4")
    (list "topic" "work")
    (list "wait" "2.2")
    (list "assert-turn-source" "llm")

    (list "note" "低档生成的答案不服务中档：切回 medium 再问 work，应重新生成" "2.4")
    (list "gm" "quality medium")
    (list "assert-ai-quality" "medium")
    (list "topic" "work")
    (list "wait" "2.4")
    (list "assert-turn-source" "llm")

    (list "note" "切回 off：不请求模型，但已有高档台词仍可回答" "2.4")
    (list "gm" "quality off")
    (list "assert-ai-quality" "off")
    (list "topic" "village")
    (list "wait" "1.2")
    (list "assert-turn-source" "cache")
    (list "press" "E")

    (list "gm" "speed 1")
    (list "note" "验收完成：档位切换、按需加载与 tier 缓存规则都对" "2.4")))
