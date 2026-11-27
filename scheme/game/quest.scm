;; quest.scm — generic multi-quest engine over data/quests.scm.
;;
;; Quest definitions (objectives, stages, dialogue, take/reward) live in
;; data/quests.scm. This module owns only mutable state and applies intents
;; against the current stage's data. It is the only module allowed to change
;; quest state: the LLM may narrate, but `apply-intent` moves state.
;;
;; Several quests advance in parallel. Each quest id has its own state:
;;   stage     current stage number
;;   progress  objective-id -> amount delivered / times observed
;;   histories per-npc conversation history used to build LLM prompts
;;
;; An objective has a `kind`:
;;   count   deliver N of a bag item type (the smith's ore, the herbs)
;;   talk    talk to the quest giver about the quest N times
;;   target  interact with a named world target N times
;; The engine tracks all three through the same `progress` slot; only the
;; intent that fills it differs (give / talk / target).
;;
;; Rewards are granted on entering a stage with a `reward` field: xp is added
;; to the shared player counter and items go into the same bag every pickup
;; uses. A `complete` stage bumps a counter the shell watches for a jingle.
;;
;; Public surface used by talk.scm / main.scm / the bridge:
;;   quest-text          combined HUD description of all live quests
;;   ore-carried         ore in the bag (legacy HUD field)
;;   quest-for-npc       quest id whose giver is this npc, or #f
;;   qtext/qstate-sym/qtopics/qobjective-carried   quest-scoped views
;;   apply-intent-for    (status . reason) for accept | give | chat/talk | target
;;   reset-quest!        back to every quest's start, xp and completions zero
;;   game:quests         (xp completions rows) for the quest log UI

(require "game.util")
(require "game.data.quests")
(require "game.inventory")

;; ---- per-quest state --------------------------------------------------------

(define *quests-state* '())   ; alist: quest-id -> state hash
(define *xp* 0)
(define *quest-completions* 0)

(define (valid-quest? id)
  (and id (quest-def id) #t))

(define (quest-def id)
  (table-ref *quests* id #f))

(define (quest-ids)
  *quest-order*)

(define (ensure-quest-state! id)
  (let ((hit (alist-get *quests-state* id)))
    (if hit
        hit
        (let ((st (make-hash-table))
              (def (quest-def id)))
          (hash-table-set! st 'stage (if def (table-ref def 'start 10) 10))
          (hash-table-set! st 'progress (make-hash-table))
          (hash-table-set! st 'histories '())
          (set! *quests-state* (alist-put *quests-state* id st))
          st))))

(define (qstate id) (ensure-quest-state! id))

(define (qget id key default)
  (table-ref (qstate id) key default))

(define (qset! id key val)
  (hash-table-set! (qstate id) key val))

;; ---- definitions ------------------------------------------------------------

(define (qfield id key default)
  (let ((def (quest-def id)))
    (if def (table-ref def key default) default)))

(define (qstages id) (qfield id 'stages (table)))
(define (qstage-num id) (qget id 'stage 0))
(define (qstage id n) (table-ref (qstages id) n #f))
(define (qcur id) (qstage id (qstage-num id)))

(define (qcur-field id key default)
  (let ((s (qcur id)))
    (if s (table-ref s key default) default)))

(define (qstate-sym id) (qcur-field id 'state 'not-offered))
(define (qset-stage! id n) (qset! id 'stage n))

(define (qobjectives id) (qfield id 'objectives (table)))
(define (qobj id obj-id)
  (if obj-id (table-ref (qobjectives id) obj-id #f) #f))

(define (qobj-field id obj-id key default)
  (let ((o (qobj id obj-id)))
    (if o (table-ref o key default) default)))

(define (obj-need id obj-id) (qobj-field id obj-id 'need 0))
(define (obj-kind id obj-id) (qobj-field id obj-id 'kind 'count))
(define (obj-type id obj-id) (qobj-field id obj-id 'type #f))
(define (obj-text id obj-id) (qobj-field id obj-id 'text ""))

(define (qprogress id obj-id)
  (if obj-id
      (table-ref (qget id 'progress (table)) obj-id 0)
      0))

(define (qset-progress! id obj-id n)
  (if obj-id
      (hash-table-set! (qget id 'progress (table)) obj-id n)))

;; One NPC may hand out several quests in sequence (老王: 矿石 → 渡船).
;; Prefer the first live one; if all are done, keep the last completed one so
;; the post-quest greeting still belongs to that chain.
(define (quest-for-npc npc)
  (let loop ((ids (quest-ids)) (done #f))
    (cond ((null? ids) done)
          ((eq? (qfield (car ids) 'giver 'nobody) npc)
           (if (eq? (qstate-sym (car ids)) 'completed)
               (loop (cdr ids) (car ids))
               (car ids)))
          (else (loop (cdr ids) done)))))

;; ---- quest text -------------------------------------------------------------

;; Interpolate {delivered} {carried} {need} against the stage's primary
;; objective. The primary objective is what the NPC's "give" topic delivers.
(define (interpolate id s)
  (let* ((obj (qcur-field id 'objective #f))
         (need (obj-need id obj))
         (type (obj-type id obj))
         (carried (if type (bag-count (string->symbol type)) 0)))
    (string-fill s
      (list (cons "{delivered}" (number->string (qprogress id obj)))
            (cons "{carried}" (number->string carried))
            (cons "{need}" (number->string need))))))

(define (qtext id)
  (interpolate id (or (qcur-field id 'quest-text "") "")))

;; What the stage's objective tracks right now, used by topic menus and prompts.
(define (qobjective-carried id)
  (let ((type (obj-type id (qcur-field id 'objective #f))))
    (if type (bag-count (string->symbol type)) 0)))

;; The HUD still gets a single string. Live quests are joined in data order;
;; completed ones drop out so the line makes room for the next objective.
(define (quest-text)
  (let loop ((ids (quest-ids)) (parts '()))
    (cond ((null? ids)
           (if (null? parts) "任务：暂无（在村里走走看看）"
               (string-join (reverse parts) "  ")))
          ((eq? (qstate-sym (car ids)) 'completed) (loop (cdr ids) parts))
          (else (loop (cdr ids) (cons (qtext (car ids)) parts))))))

;; Legacy HUD field: ore picked up but not handed in.
(define (ore-carried)
  (bag-count 'item/material/ore))

(define (qreason id key)
  (table-ref (qfield id 'reasons (table)) key ""))

(define (qhint id status)
  (table-ref (qfield id 'hints (table)) status ""))

;; ---- topic menus ------------------------------------------------------------

;; The accepted stage has separate menus for "carrying" and "empty", so the
;; give entry only shows when there is something to hand in.
(define (qtopics id)
  (let ((key (cond ((not (eq? (qstate-sym id) 'accepted)) 'topics)
                   ((> (qobjective-carried id) 0) 'topics-carry)
                   (else 'topics-empty))))
    (table-ref (qcur id) key #f)))

;; ---- history ----------------------------------------------------------------

(define (hist-add id npc speaker text)
  (let ((old (or (qget id 'histories '()) '())))
    (let ((prev (or (alist-get old npc) '()))
          (next (cons (cons speaker text) '())))
      (let ((merged (cons (car next) prev)))
        (qset! id 'histories
          (alist-put old npc
            (if (> (length merged) 12)
                (reverse (take-n (reverse merged) 12))
                merged)))))))

(define (hist-recent id npc n)
  (let* ((h (or (alist-get (qget id 'histories '()) npc) '()))
         (recent (reverse (take-n h n))))
    (cond ((null? recent) "")
          (else (apply string-append
                        (map (lambda (p) (string-append (car p) ": " (cdr p) ". "))
                             recent))))))

;; ---- rewards ----------------------------------------------------------------

(define (grant-one-item! entry)
  (let ((type (table-ref entry 'type #f))
        (count (table-ref entry 'count 1)))
    (if type (bag-add! (string->symbol type) count))))

;; `items` is either one (type count) table or a list of them. A hash table is
;; not a pair, so `pair?` is enough to tell the two shapes apart.
(define (grant-items! items)
  (cond ((not items) #f)
        ((pair? items)
         (let loop ((xs items))
           (if (null? xs) #f
               (begin (grant-one-item! (car xs)) (loop (cdr xs))))))
        (else (grant-one-item! items))))

;; ---- stage transitions ------------------------------------------------------

(define (apply-stage-effects! id stage)
  ;; A stage-entry `take` costs bag items. It is usually already paid by the
  ;; give intent, so a second take on the completed stage is a safe no-op.
  (let ((take (table-ref stage 'take #f)))
    (if take
        (let ((type (table-ref take 'type #f))
              (n (table-ref take 'count 0)))
          (if type (bag-remove! (string->symbol type) n)))))
  (let ((reward (table-ref stage 'reward #f)))
    (if reward
        (begin
          (set! *xp* (+ *xp* (table-ref reward 'xp 0)))
          (grant-items! (table-ref reward 'items #f)))))
  (if (table-ref stage 'complete #f)
      (set! *quest-completions* (+ *quest-completions* 1))))

(define (advance-to! id target-n)
  (qset-stage! id target-n)
  (let ((stage (qcur id)))
    (apply-stage-effects! id stage)
    (cons 'accepted (or (table-ref stage 'say) ""))))

;; ---- intent application -----------------------------------------------------
;; The only place quest state changes. Returns (status . reason);
;; status ∈ accepted | rejected | ignored. Reason text is quest data, so the
;; mechanism HUD stays script-agnostic.

(define (apply-intent-for id intent)
  (if (not (valid-quest? id))
      (cons 'ignored "")
      (let ((stage (qcur id))
            (state (qstate-sym id)))
        (cond
          ((eq? intent 'accept)
           (cond ((eq? state 'not-offered)
                  (let ((reason (cdr (advance-to! id (table-ref stage 'on-accept)))))
                    (cons 'accepted
                          (if (string=? reason "") (qreason id 'accept-ok) reason))))
                 ((eq? state 'accepted) (cons 'ignored (qreason id 'accept-dup)))
                 ((eq? state 'completed) (cons 'rejected (qreason id 'accept-done)))
                 (else (cons 'ignored ""))))

          ((eq? intent 'give)
           (cond ((eq? state 'accepted)
                  (let* ((obj (table-ref stage 'objective #f))
                         (kind (if obj (obj-kind id obj) 'count))
                         (need (obj-need id obj))
                         (type (obj-type id obj))
                         (carried (if type (bag-count (string->symbol type)) 0))
                         (remaining (- need (qprogress id obj)))
                         (n (min carried remaining)))
                    (if (eq? kind 'count)
                        (cond ((<= n 0) (cons 'rejected (qreason id 'give-empty)))
                              (else
                               (if type (bag-remove! (string->symbol type) n))
                               (qset-progress! id obj (+ (qprogress id obj) n))
                               (if (>= (qprogress id obj) need)
                                   (advance-to! id (table-ref stage 'on-give-complete))
                                   (cons 'accepted
                                     (string-fill (qreason id 'give-partial)
                                       (list (cons "{n}" (number->string n))
                                             (cons "{delivered}" (number->string (qprogress id obj)))
                                             (cons "{need}" (number->string need))))))))
                        (cons 'rejected (qreason id 'give-empty)))))
                 ((eq? state 'not-offered) (cons 'rejected (qreason id 'give-not-accepted)))
                 ((eq? state 'completed) (cons 'rejected (qreason id 'give-done)))
                 (else (cons 'ignored ""))))

          ;; chat / talk: advance a `talk` objective of the current stage.
          ((eq? intent 'talk)
           (let* ((obj (table-ref stage 'objective #f))
                  (kind (if obj (obj-kind id obj) 'count))
                  (need (obj-need id obj)))
             (if (and obj (eq? kind 'talk) (eq? state 'accepted)
                      (< (qprogress id obj) need))
                 (begin
                   (qset-progress! id obj (+ (qprogress id obj) 1))
                   (if (>= (qprogress id obj) need)
                       (advance-to! id (table-ref stage 'on-talk-complete))
                       (cons 'accepted (qreason id 'talk-progress))))
                 (cons 'ignored ""))))

          ;; target: advance a `target` objective when Godot reports an
          ;; interaction with the named world object.
          ((eq? intent 'target)
           (let* ((obj (table-ref stage 'objective #f))
                  (kind (if obj (obj-kind id obj) 'count))
                  (need (obj-need id obj))
                  (want (qobj-field id obj 'target #f)))
             (if (and want (eq? kind 'target) (eq? state 'accepted)
                      (< (qprogress id obj) need))
                 (begin
                   (qset-progress! id obj (+ (qprogress id obj) 1))
                   (if (>= (qprogress id obj) need)
                       (advance-to! id (table-ref stage 'on-target-complete))
                       (cons 'accepted (qreason id 'target-progress))))
                 (cons 'ignored ""))))

          (else (cons 'ignored (qreason id 'idle)))))))

;; One-argument compatibility form (the active quest is the first one).
(define (apply-intent intent . maybe-id)
  (apply-intent-for (if (null? maybe-id) (car (quest-ids)) (car maybe-id)) intent))

;; ---- bridge entries ---------------------------------------------------------

;; Godot reports an E interaction here; any quest tracking that target id gets
;; its objective advanced. Returns #t when a quest actually moved.
(define (game:quest-target target)
  (let loop ((ids (quest-ids)) (fired 0))
    (if (null? ids)
        (> fired 0)
        (let* ((id (car ids))
               (obj (qcur-field id 'objective #f))
               (want (qobj-field id obj 'target #f)))
          (if (and want (string=? want target))
              (let ((v (apply-intent-for id 'target)))
                (loop (cdr ids)
                      (+ fired (if (eq? (car v) 'accepted) 1 0))))
              (loop (cdr ids) fired))))))

;; (xp completions rows) where each row is
;;   (id title state description ((objective-text done need) ...))
(define (objective-progress-row id obj-id)
  (list (obj-text id obj-id) (qprogress id obj-id) (obj-need id obj-id)))

(define (objective-rows id)
  (let loop ((ids (qfield id 'objective-order '())) (rows '()))
    (if (null? ids)
        (reverse rows)
        (loop (cdr ids) (cons (objective-progress-row id (car ids)) rows)))))

(define (game:quests)
  (list *xp*
        *quest-completions*
        (let loop ((ids (quest-ids)) (rows '()))
          (if (null? ids)
              (reverse rows)
              (let* ((id (car ids))
                     (def (quest-def id)))
                (loop (cdr ids)
                      (cons (list (symbol->string id)
                                  (table-ref def 'title "")
                                  (symbol->string (qstate-sym id))
                                  (qtext id)
                                  (objective-rows id))
                            rows)))))))

;; ---- reset ------------------------------------------------------------------

(define (reset-quest!)
  (set! *quests-state* '())
  (set! *xp* 0)
  (set! *quest-completions* 0))

;; ---- save slots -------------------------------------------------------------
(register-save-slot! 'xp (lambda () *xp*) (lambda (v) (set! *xp* v)) 0)
(register-save-slot! 'completions (lambda () *quest-completions*)
  (lambda (v) (set! *quest-completions* v)) 0)
(register-save-slot! 'quests (lambda () *quests-state*)
  (lambda (v) (set! *quests-state* v)) '()
  (lambda (rows)
    (map (lambda (row) (cons (car row) (save:quest-table (cdr row)))) rows)))
