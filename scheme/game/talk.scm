;; talk.scm — conversation flow: topic menu, greetings, prompts, learned lines.
;;
;; Order matters: Scheme judges the intent FIRST (quest.scm changes state),
;; then the LLM narrates — it may never see a state it did not produce.
;;
;; Each NPC may be the giver of one quest. Dialogue that belongs to that quest
;; (menu, greeting, prompt, canned milestone) is read from the quest's data and
;; state; villagers without a quest keep the shared village menu and pure LLM
;; chat. Several quests can be active at once because all state is keyed by
;; quest id, not by a single global stage.

(require "game.util")
(require "game.data.dialogue")
(require "game.time")
(require "game.llm")
(require "game.npcs")
(require "game.quest")
(require "game.story")

;; ---- topic menu per NPC, depending on its quest's state ---------------------
;; The quest giver's menu comes from the current stage's data (the accepted
;; stage has distinct carry/empty menus); everyone else uses the shared menu.
;; The {carried} placeholder in the give label is interpolated here.

;; GDScript passes npc ids as strings; convert once here, symbols inside.
(define (game:topics npc)
  (topics-for (string->symbol npc)))

(define (topics-for npc)
  (let* ((qid (quest-for-npc npc))
         (menu (or (and qid (qtopics qid)) *default-topics*))
         (carried (number->string
                    (if qid (qobjective-carried qid) (ore-carried)))))
    (map (lambda (p)
           (cons (car p) (string-replace-all (cdr p) "{carried}" carried)))
         menu)))

;; The bridge passes topics back as symbols; strings also tolerated.
(define (topic-key t)
  (cond ((symbol? t) t)
        ((string? t) (string->symbol t))
        (else 'greet)))

;; ---- greetings (canned; cheap, no LLM) --------------------------------------
;; The giver's greeting follows its quest's current stage; others use their
;; canned line from the roster.

(define (game:greet npc)
  (greeting-for (string->symbol npc)))

(define (greeting-for npc)
  (let* ((qid (quest-for-npc npc))
         (line (or (and qid (qcur-field qid 'greet #f))
                   (table-ref (npc-fallback npc) 'greet)
                   "……")))
    (list line (if qid (qtext qid) "") (ore-carried))))

;; ---- prompt / fallback ------------------------------------------------------

;; Situation comes from the same sources the presentation layer reads: the
;; clock/weather from time.scm and the NPC's current schedule step from
;; npcs.scm. Scheme already decides all three, so no world query is needed.
;; Labels live in data/dialogue.scm; an unknown symbol falls back to its name.
(define (situation-label tbl sym)
  (let ((v (table-ref tbl sym #f)))
    (if (string? v) v (symbol->string sym))))

(define (two-digit n)
  (let ((s (number->string n)))
    (if (< (string-length s) 2) (string-append "0" s) s)))

;; The template itself (and every literal in it) lives in data/dialogue.scm;
;; this function only supplies the per-turn values.
(define (build-prompt npc player-text status qid)
  (let* ((now (clock-at *tick*))
         (hour (cadr now))
         (activity (cadr (npc-plan npc hour))))
    (string-fill *prompt-template*
      (list (cons "{persona}" (npc-persona npc))
            (cons "{sys}" *sys-instruction*)
            (cons "{quest}" (if qid (qtext qid) "在村里随便走走"))
            (cons "{item}" (if qid (qfield qid 'pack-item "") ""))
            (cons "{carried}" (number->string
                                (if qid (qobjective-carried qid) (ore-carried))))
            (cons "{status}" (symbol->string (car status)))
            (cons "{reason}" (cdr status))
            (cons "{hint}" (if qid (qhint qid (car status)) ""))
            (cons "{day}" (number->string (car now)))
            (cons "{hour}" (two-digit hour))
            (cons "{minute}" (two-digit (caddr now)))
            (cons "{weather}" (situation-label *weather-labels* (current-weather)))
            (cons "{who}" (npc-display npc))
            (cons "{activity}" (situation-label *activity-labels* activity))
            (cons "{story}" (story:prompt-line))
            (cons "{history}" (hist-recent (or qid 'chat) npc 6))
            (cons "{player}" player-text)))))

;; Debug: the exact prompt a turn would build, without running the model or
;; changing any state. Acceptance uses it to verify that time/weather/schedule
;; reach the LLM input, which is otherwise only observable by reading a reply.
(define (game:debug-talk-prompt npc topic)
  (let* ((n (string->symbol npc))
         (t (topic-key topic))
         (qid (quest-for-npc n))
         (text (or (table-ref *topic-utterances* t) "")))
    (build-prompt n text (cons 'ignored "") qid)))

(define (fallback-line npc topic)
  (or (table-ref (npc-fallback npc) topic) "……"))

;; ---- learned lines (cache) --------------------------------------------------
;; An LLM-generated line is proposed once, then it belongs to the village.
;; Each entry remembers the AI level it was made at (llm.scm tiers): the same
;; (npc, topic, quest-state, situation) at the same or a lower level replays it
;; without touching the model; a higher level regenerates and overwrites it.
;; The situation bucket keeps a sunny noon line from being replayed on a rainy
;; night — otherwise injecting weather into the prompt would not change any
;; reply once that topic had been cached. Per-minute time would make every turn
;; a miss, so it is bucketed into four parts of the day.
;; Returns (line source learned?): source ∈ "llm" | "cache" | "canned" | "fallback"
(define *learned* '())

(define (daypart hour)
  (cond ((< hour 6) 'night)
        ((< hour 12) 'morning)
        ((< hour 18) 'afternoon)
        ((< hour 22) 'evening)
        (else 'night)))

(define (learn-key npc t qid)
  (let* ((state (if qid (qstate-sym qid) 'not-offered))
         (now (clock-at *tick*))
         (situation (string-append (symbol->string (daypart (cadr now))) "-"
                                   (symbol->string (current-weather)))))
    (string-append (symbol->string npc) "/" (symbol->string t) "/"
      (cond ((eq? state 'completed) "2")
            ((eq? state 'accepted)  "1")
            (else "0"))
      "/" situation)))

;; Cache values are (line . tier); a tier that does not serve the current
;; setting is treated as a miss, so the model may be asked again.
(define (learn-get key)
  (let ((hit (alist-get *learned* key)))
    (and (pair? hit)
         (string? (car hit))
         (tier-serves? (cdr hit))
         (car hit))))

(define (learn-put! key line)
  (set! *learned* (alist-put *learned* key (cons line *ai-quality*))))

;; Drop the cache so edited content is visible immediately after game:reload.
(define (reset-talk!)
  (set! *learned* '()))

(define (llm-line npc t qid prompt)
  (let ((key (learn-key npc t qid)))
    (let ((hit (learn-get key)))
      (cond (hit (list hit "cache" #t))
            ((not (ai-asks?))
             ;; off (or no model loaded): the canned village line answers.
             (list (fallback-line npc t) "canned" #f))
            (else
             (let ((l (generate-line prompt (quality-tokens))))
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
;;   (topic intent verdict-status reason source model-desc prefill-tps decode-tps ai-quality).
(define (game:talk npc topic)
  (talk (string->symbol npc) topic))

(define (talk npc topic)
  (let* ((t (topic-key topic))
         (qid (quest-for-npc npc))
         (quest-topic (and qid (or (eq? t 'quest) (eq? t 'give))))
         (intent (cond ((and quest-topic (eq? t 'quest)
                             (eq? (qstate-sym qid) 'not-offered)) 'accept)
                       ((and quest-topic (eq? t 'give)) 'give)
                       ((and quest-topic (eq? t 'quest)) 'talk)
                       (else 'chat)))
         (verdict (if qid (apply-intent-for qid intent) (cons 'ignored "")))
         (player-text
           (cond ((eq? intent 'accept) (qfield qid 'accept-text "……"))
                 ((and (eq? intent 'give) (eq? (car verdict) 'accepted))
                  (qfield qid 'give-text "……"))
                 ((or (eq? t 'quest) (eq? t 'give)) (or (table-ref *topic-utterances* 'work) "……"))
                 (else (or (table-ref *topic-utterances* t) "……"))))
         ;; Path 2: quest happenings stay canned (deterministic by design);
         ;; Path 3: village / work / plain chat goes through the learned cache,
         ;; then the LLM unless the AI level is off (llm-line handles both).
         (reply
           (cond ((and quest-topic (not (eq? (car verdict) 'ignored)))
                  ;; Quest milestones are scripted even without a model: the
                  ;; verdict must match the line ("rejected" can never say
                  ;; "I'll take it").
                  (list (canned-quest-line npc qid verdict) "canned" #f))
                 (quest-topic (plain-line npc t))
                 (else (llm-line npc t qid (build-prompt npc player-text verdict qid)))))
         ;; llm-perf numbers only belong to a turn that actually ran the model.
         (perf (if (string=? (cadr reply) "llm")
                   (game:last-perf)
                   (list 0.0 0.0)))
         (prefill-perf (car perf))
         (decode-perf (cadr perf)))
    (hist-add (or qid 'chat) npc *player-speaker* player-text)
    (hist-add (or qid 'chat) npc (npc-display npc) (car reply))
    ;; The 4th element drives the "📖 记住了" marker; the 5th is the HUD's
    ;; mechanism trace. Symbols become plain strings through the GDExtension.
    (list (car reply) (if qid (qtext qid) "") (ore-carried) (caddr reply)
          (list (symbol->string t)
                (symbol->string intent)
                (symbol->string (car verdict))
                (cdr verdict)
                (cadr reply)
                (if (string? *model-desc*) *model-desc* "")
                prefill-perf
                decode-perf
                (symbol->string *ai-quality*)))))

;; The LLM is told what happened (verdict), but the canonical line for quest
;; milestones is scripted — the same reason cutscenes are scripted.
;; Accepted milestones use the current stage's `say` line from quest data;
;; rejected milestones use the current stage's `say-reject` line. The speaker
;; prefix is the giver's display name, not a literal.
(define (canned-quest-line npc qid verdict)
  (let ((stage (qcur qid))
        (prefix (string-append (npc-display npc) "：")))
    (cond ((eq? (car verdict) 'accepted)
           (string-append prefix (or (table-ref stage 'say) "")))
          ((eq? (car verdict) 'rejected)
           (string-append prefix (or (table-ref stage 'say-reject) "")))
          (else (fallback-line npc 'work)))))
