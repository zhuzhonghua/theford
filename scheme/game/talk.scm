;; talk.scm — conversation flow: topic menu, greetings, prompts, learned lines.
;;
;; Order matters: Scheme judges the intent FIRST (quest.scm changes state),
;; then the LLM narrates — it may never see a state it did not produce.

(require "game.util")
(require "game.llm")
(require "game.npcs")
(require "game.quest")

;; ---- topic menu per NPC, depending on quest state ---------------------------

(define (game:topics npc)
  (cond ((equal? npc "smith")
         (append
           (list (cons 'greet "打个招呼")
                 (cons 'village "聊聊村子")
                 (cons 'work "问问活计"))
           (cond ((eq? *quest-state* 'not-offered)
                  (list (cons 'quest "接任务")))
                 ((eq? *quest-state* 'accepted)
                  (if (> *carried* 0)
                      (list (cons 'give (string-append "交矿石（背上 " (number->string *carried*) " 块）")))
                      (list (cons 'quest "聊聊进度"))))
                 (else '()))))
        (else
          (list (cons 'greet "打个招呼")
                (cons 'village "聊聊村子")
                (cons 'work "问问活计")))))

;; The bridge passes topics back as symbols; strings also tolerated.
(define (topic-key t)
  (cond ((symbol? t) t)
        ((string? t) (string->symbol t))
        (else 'greet)))

;; ---- greetings (canned; cheap, no LLM) --------------------------------------

(define (game:greet npc)
  (let ((line (cond ((equal? npc "smith")
                     (cond ((eq? *quest-state* 'not-offered)
                            "老王：来了？坐。炉火不等人，有什么话快说。")
                           ((eq? *quest-state* 'accepted)
                            "老王：矿石找着了没？河边滩上冲下来的石头里看好料。")
                           (else "老王：哈哈，成事之人。到屋里坐，我去给你拿剑。")))
                    (else
                     (let ((fb (alist-get (npc-fallback npc) 'greet)))
                       (or fb "……"))))))
    (list line (quest-text) *carried*)))

;; ---- prompt / fallback ------------------------------------------------------

(define (build-prompt npc player-text status)
  (let ((persona (npc-persona npc)))
    (string-append
      "<|im_start|>system\n"
      persona *sys-instruction* "<|im_end|>\n"
      "<|im_start|>user\n"
      "当前任务状态：" (quest-text) "\n"
      "玩家背包：铁矿石 x" (number->string *carried*) "\n"
      "刚刚的判定：Scheme 结果=" (symbol->string (car status))
      "，原因=" (cdr status) "\n"
      (verdict-hint (car status)) "\n\n"
      "对话记录：\n"
      (hist-recent npc 6) "\n"
      "玩家：" player-text "<|im_end|>\n"
      ;; Qwen3 thinking-off prefill (same trick as test/npc-demo.scm):
      "<|im_start|>assistant\n<think>\n\n</think>")))

(define (fallback-line npc topic)
  (or (alist-get (npc-fallback npc) topic)
      (cond ((eq? topic 'quest) "老王：正忙，过会儿再说。")
            ((eq? topic 'give)  "老王：先把矿石找来再说。")
            (else "……"))))

;; ---- learned lines (cache) --------------------------------------------------
;; Same idea as openworld's learned.ts: an LLM-generated line is proposed
;; once, then it belongs to the village. For the exact same
;; (npc, topic, quest-state) the replayed answer is deterministic — the
;; second ask never hits the model. Returns (line source learned?):
;;   source ∈ "llm" | "cache" | "canned" | "fallback"
(define *learned* '())

(define (learn-key npc t)
  (string-append npc "/" (symbol->string t) "/"
    (cond ((eq? *quest-state* 'completed) "2")
          ((eq? *quest-state* 'accepted)  "1")
          (else "0"))))

(define (learn-get key)
  (let ((hit (alist-get *learned* key)))
    (and (string? hit) (not (string=? hit "")) hit)))

(define (learn-put! key line)
  (set! *learned* (alist-put *learned* key line)))

(define (llm-line npc t prompt)
  (let ((key (learn-key npc t)))
    (let ((hit (learn-get key)))
      (cond (hit (list hit "cache" #t))
            (else
             (let ((l (generate-line prompt 120)))
               (cond ((string=? l "")
                      (list (fallback-line npc t) "fallback" #f))
                     (else
                      (learn-put! key l)
                      (list l "llm" #f)))))))))

(define (plain-line npc t)
  (list (fallback-line npc t) "canned" #f))

;; One conversational turn: canned path and LLM path share the same plumbing.
;; Return shape (all elements visible to the mechanism HUD):
;;   (reply quest-text carried learned? decision)
;; where decision =
;;   (topic intent verdict-status reason source model-desc prefill-tps decode-tps).
(define (game:talk npc topic)
  (let* ((t (topic-key topic))
         (quest-topic (and (equal? npc "smith") (or (eq? t 'quest) (eq? t 'give))))
         (intent (cond ((and (eq? t 'quest) (eq? *quest-state* 'not-offered)) 'accept)
                       ((eq? t 'give) 'give)
                       (else 'chat)))
         (verdict (apply-intent intent))
         (player-text
           (cond ((eq? intent 'accept) "我想接下你的任务。")
                 ((and (eq? intent 'give) (eq? (car verdict) 'accepted))
                  "给你，矿石都在这儿。")
                 ((or (eq? t 'quest) (eq? t 'give)) (or (alist-get *topic-utterances* 'work) "……"))
                 (else (or (alist-get *topic-utterances* t) "……"))))
         ;; Path 2: quest happenings stay canned (deterministic by design);
         ;; Path 3: village / work / plain chat goes through the LLM,
         ;; then through the learned cache.
         (reply
           (cond ((and quest-topic (not (eq? (car verdict) 'ignored)))
                  ;; Quest milestones are scripted even without a model: the
                  ;; verdict must match the line ("rejected" can never say
                  ;; "I'll take it").
                  (list (canned-quest-line npc verdict) "canned" #f))
                 ((not *use-llm*) (plain-line npc t))
                 (quest-topic (plain-line npc t))
                 (else (llm-line npc t (build-prompt npc player-text verdict)))))
         ;; llm-perf numbers only belong to a turn that actually ran the model.
         (perf (if (string=? (cadr reply) "llm")
                   (game:last-perf)
                   (list 0.0 0.0)))
         (prefill-perf (car perf))
         (decode-perf (cadr perf)))
    (hist-add npc "玩家" player-text)
    (hist-add npc (npc-display npc) (car reply))
    ;; The 4th element drives the "📖 记住了" marker; the 5th is the HUD's
    ;; mechanism trace. Symbols become plain strings through the GDExtension.
    (list (car reply) (quest-text) *carried* (caddr reply)
          (list (symbol->string t)
                (symbol->string intent)
                (symbol->string (car verdict))
                (cdr verdict)
                (cadr reply)
                (if (string? *model-desc*) *model-desc* "")
                prefill-perf
                decode-perf))))

;; The LLM is told what happened (verdict), but the canonical line for quest
;; milestones is scripted — the same reason cutscenes are scripted.
(define (canned-quest-line npc verdict)
  (cond ((eq? (car verdict) 'accepted)
         (cond ((eq? *quest-state* 'accepted)
                "老王：好嘞！三块铁矿石，河边滩上冲下来的石头里看好料。找着了拿来我这儿。")
               ((eq? *quest-state* 'completed)
                "老王：得了！矿石齐了，剑也成了。给你——往后就是渡口村的人了。")))
        ((eq? (car verdict) 'rejected)
         (cond ((eq? *quest-state* 'completed)
                "老王：矿石早收齐了，剑不是已经给你了吗？")
               ((eq? *quest-state* 'not-offered)
                "老王：活儿还没接呢，先把矿石找来再说。")
               (else "老王：这可不行，先把矿石找来。")))
        (else (fallback-line npc 'work))))
