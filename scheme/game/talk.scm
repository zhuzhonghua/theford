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
  (let ((persona (or (alist-get *personas* npc) "你是村里的一位 NPC。")))
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
;; second ask never hits the model. Returns a (line . learned?) pair.
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
      (cond (hit (cons hit #t))
            (else
             (let ((l (generate-line prompt 120)))
               (cond ((string=? l "") (cons (fallback-line npc t) #f))
                     (else (learn-put! key l) (cons l #f)))))))))

(define (plain-line npc t)
  (cons (fallback-line npc t) #f))

;; One conversational turn: canned path and LLM path share the same plumbing.
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
           (cond ((not *use-llm*) (plain-line npc t))
                 ((and quest-topic (not (eq? (car verdict) 'ignored)))
                  (cons (canned-quest-line npc verdict) #f))
                 (quest-topic (plain-line npc t))
                 (else (llm-line npc t (build-prompt npc player-text verdict))))))
    (hist-add npc "玩家" player-text)
    (hist-add npc (or (alist-get *npc-display* npc) npc) (car reply))
    ;; (reply quest-text carried learned?) — learned? drives the "📖 记住了"
    ;; marker in the dialog panel.
    (list (car reply) (quest-text) *carried* (cdr reply))))

;; The LLM is told what happened (verdict), but the canonical line for quest
;; milestones is scripted — the same reason cutscenes are scripted.
(define (canned-quest-line npc verdict)
  (cond ((eq? (car verdict) 'accepted)
         (cond ((eq? *quest-state* 'accepted)
                "老王：好嘞！三块铁矿石，河边滩上冲下来的石头里看好料。找着了拿来我这儿。")
               ((eq? *quest-state* 'completed)
                "老王：得了！矿石齐了，剑也成了。给你——往后就是渡口村的人了。")))
        ((eq? (car verdict) 'rejected) "老王：这可不行，先把矿石找来。")
        (else (fallback-line npc 'work))))
