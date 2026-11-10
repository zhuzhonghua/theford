;; talk.scm — conversation flow: topic menu, greetings, prompts, learned lines.
;;
;; Order matters: Scheme judges the intent FIRST (quest.scm changes state),
;; then the LLM narrates — it may never see a state it did not produce.

(require "game.util")
(require "game.data.dialogue")
(require "game.llm")
(require "game.npcs")
(require "game.quest")

;; ---- topic menu per NPC, depending on quest state ---------------------------
;; The quest giver's menu comes from the current stage's data (the accepted
;; stage has distinct carry/empty menus); everyone else uses the shared menu.
;; The {carried} placeholder in the give label is interpolated here.

;; GDScript passes npc ids as strings; convert once here, symbols inside.
(define (game:topics npc)
  (topics-for (string->symbol npc)))

(define (topics-for npc)
  (let ((menu (or (and (eq? npc (quest-giver)) (quest-topic-menu))
                  *default-topics*)))
    (let ((carried (number->string *carried*)))
      (map (lambda (p)
             (cons (car p) (string-replace-all (cdr p) "{carried}" carried)))
           menu))))

;; The bridge passes topics back as symbols; strings also tolerated.
(define (topic-key t)
  (cond ((symbol? t) t)
        ((string? t) (string->symbol t))
        (else 'greet)))

;; ---- greetings (canned; cheap, no LLM) --------------------------------------
;; The quest giver's greeting follows the current stage; others use their
;; canned line from the roster.

(define (game:greet npc)
  (greeting-for (string->symbol npc)))

(define (greeting-for npc)
  (let ((line (or (and (eq? npc (quest-giver))
                       (table-ref (current-stage) 'greet))
                  (table-ref (npc-fallback npc) 'greet)
                  "……")))
    (list line (quest-text) *carried*)))

;; ---- prompt / fallback ------------------------------------------------------

;; The template itself (and every literal in it) lives in data/dialogue.scm;
;; this function only supplies the per-turn values.
(define (build-prompt npc player-text status)
  (string-fill *prompt-template*
    (list (cons "{persona}" (npc-persona npc))
          (cons "{sys}" *sys-instruction*)
          (cons "{quest}" (quest-text))
          (cons "{item}" (quest-field 'pack-item ""))
          (cons "{carried}" (number->string *carried*))
          (cons "{status}" (symbol->string (car status)))
          (cons "{reason}" (cdr status))
          (cons "{hint}" (verdict-hint (car status)))
          (cons "{history}" (hist-recent npc 6))
          (cons "{player}" player-text))))

(define (fallback-line npc topic)
  (or (table-ref (npc-fallback npc) topic) "……"))

;; ---- learned lines (cache) --------------------------------------------------
;; An LLM-generated line is proposed once, then it belongs to the village.
;; For the exact same (npc, topic, quest-state) the replayed answer is
;; deterministic — the second ask never hits the model.
;; Returns (line source learned?): source ∈ "llm" | "cache" | "canned" | "fallback"
(define *learned* '())

(define (learn-key npc t)
  (string-append (symbol->string npc) "/" (symbol->string t) "/"
    (cond ((eq? *quest-state* 'completed) "2")
          ((eq? *quest-state* 'accepted)  "1")
          (else "0"))))

(define (learn-get key)
  (let ((hit (alist-get *learned* key)))
    (and (string? hit) (not (string=? hit "")) hit)))

(define (learn-put! key line)
  (set! *learned* (alist-put *learned* key line)))

;; Drop the cache so edited content is visible immediately after game:reload.
(define (reset-talk!)
  (set! *learned* '()))

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
  (talk (string->symbol npc) topic))

(define (talk npc topic)
  (let* ((t (topic-key topic))
         (quest-topic (and (eq? npc 'smith) (or (eq? t 'quest) (eq? t 'give))))
         (intent (cond ((and (eq? t 'quest) (eq? *quest-state* 'not-offered)) 'accept)
                       ((eq? t 'give) 'give)
                       (else 'chat)))
         (verdict (apply-intent intent))
         (player-text
           (cond ((eq? intent 'accept) (quest-field 'accept-text "……"))
                 ((and (eq? intent 'give) (eq? (car verdict) 'accepted))
                  (quest-field 'give-text "……"))
                 ((or (eq? t 'quest) (eq? t 'give)) (or (table-ref *topic-utterances* 'work) "……"))
                 (else (or (table-ref *topic-utterances* t) "……"))))
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
    (hist-add npc *player-speaker* player-text)
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
;; Accepted milestones use the current stage's `say` line from quest data;
;; rejected milestones use the current stage's `say-reject` line. The speaker
;; prefix is the giver's display name, not a literal.
(define (canned-quest-line npc verdict)
  (let ((stage (current-stage))
        (prefix (string-append (npc-display npc) "：")))
    (cond ((eq? (car verdict) 'accepted)
           (string-append prefix (or (table-ref stage 'say) "")))
          ((eq? (car verdict) 'rejected)
           (string-append prefix (or (table-ref stage 'say-reject) "")))
          (else (fallback-line npc 'work)))))
