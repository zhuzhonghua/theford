;; quest.scm — generic quest engine over data/quests.scm.
;;
;; Quest definitions (objectives, stages, dialogue, take/reward) live in
;; data/quests.scm. This module only holds mutable state and applies intents
;; against the current stage's data. It is the only module allowed to change
;; quest state: the LLM may narrate, but `apply-intent` moves state.
;;
;; Public surface (unchanged so talk.scm keeps working):
;;   *quest-state*  symbol: not-offered | accepted | completed
;;   ore-carried    ore picked up but not handed in (the bag's ore stack)
;;   *delivered*    ore handed to the smith
;;   quest-text     current HUD description
;;   apply-intent   (status . reason) for accept | give | chat
;;   verdict-hint   LLM steering per verdict status
;;   (game:status aggregates quest + clock; it lives in main.scm)
;;
;; Counts are not mirrored here: what the smith's objective counts is the bag's
;; ore stack (inventory.scm), so taking and handing in move the same numbers.

(require "game.util")
(require "game.data.quests")
(require "game.inventory")

;; The active quest is the smith-ore chain (only one quest for now).
(define *active-quest* 'smith-ore)

(define (quest-def)
  (table-ref *quests* *active-quest*))

;; One field of the active quest's definition, with a structural default.
(define (quest-field key default)
  (table-ref (quest-def) key default))

;; Mechanism-trace text and LLM steering lines are quest data too.
(define (quest-reason key)
  (table-ref (quest-field 'reasons (table)) key ""))

(define (quest-giver)
  (quest-field 'giver 'smith))

(define (quest-stages)
  (quest-field 'stages (table)))

(define (quest-objectives)
  (quest-field 'objectives (table)))

(define (current-stage-num)
  *stage*)

(define (current-stage)
  (table-ref (quest-stages) (current-stage-num)))

;; Current stage's topic menu. The accepted stage has separate menus for
;; "carrying" and "empty", so the give entry only shows when it can be used.
(define (quest-topic-menu)
  (let* ((stage (current-stage))
         (key (cond ((not (eq? *quest-state* 'accepted)) 'topics)
                    ((> (ore-carried) 0) 'topics-carry)
                    (else 'topics-empty))))
    (table-ref stage key)))

(define (objective-need obj-id)
  (let ((obj (table-ref (quest-objectives) obj-id)))
    (if obj (table-ref obj 'need 0) 0)))

;; ---- mutable state -----------------------------------------------------------

(define *stage* (quest-field 'start 10))  ; current stage number
(define *delivered* 0)
(define *histories* '())

;; What the objective counts is what the player actually carries.
(define (ore-carried)
  (bag-count 'item/material/ore))

;; The state symbol comes from the stage's own data, so new stages need no
;; mapping table in code.
(define (stage->state n)
  (let ((stage (table-ref (quest-stages) n)))
    (if stage (table-ref stage 'state 'not-offered) 'not-offered)))

(define *quest-state* (stage->state *stage*))

(define (set-stage! n)
  (set! *stage* n)
  (set! *quest-state* (stage->state n)))

;; Back to the quest's start, as if the game just booted. Used by game:reload
;; after the data files have been re-read; game:reload empties the bag right
;; after, so the whole run starts from the same state.
(define (reset-quest!)
  (set-stage! (quest-field 'start 10))
  (set! *delivered* 0)
  (set! *histories* '()))

;; ---- history (unchanged) -----------------------------------------------------

(define (hist-add npc speaker text)
  (let ((old (or (alist-get *histories* npc) '())))
    (let ((next (cons (cons speaker text) old)))
      (set! *histories*
        (alist-put *histories* npc
          (if (> (length next) 12)
              (reverse (take-n (reverse next) 12))
              next))))))

(define (hist-recent npc n)
  (let* ((h (or (alist-get *histories* npc) '()))
         (recent (reverse (take-n h n))))
    (cond ((null? recent) "")
          (else (apply string-append
                        (map (lambda (p) (string-append (car p) ": " (cdr p) ". "))
                             recent))))))

;; ---- quest text --------------------------------------------------------------

;; Interpolate {delivered} {carried} {need} placeholders in a stage's
;; quest-text, using the active objective's need.
(define (interpolate-quest-text s)
  (let* ((stage (current-stage))
         (obj-id (table-ref stage 'objective))
         (need (objective-need obj-id)))
    (string-replace-all
      (string-replace-all
        (string-replace-all s "{delivered}" (number->string *delivered*))
        "{carried}" (number->string (ore-carried)))
      "{need}" (number->string need))))

(define (quest-text)
  (let ((stage (current-stage)))
    (interpolate-quest-text (or (table-ref stage 'quest-text) ""))))

;; ---- intent application ------------------------------------------------------

;; Apply stage-entry effects: take items from the bag, grant rewards.
(define (apply-stage-effects! stage)
  (let ((take (table-ref stage 'take)))
    (when take
      (let ((n (min (ore-carried) (table-ref take 'count 0))))
        (bag-remove! 'item/material/ore n)
        (set! *delivered* (+ *delivered* n)))))
  ;; The reward is still recorded only: granting items and xp is the reward
  ;; step of the quest phase, not the bag's.
  (let ((reward (table-ref stage 'reward)))
    (when reward #t)))

;; Advance to a target stage, applying its entry effects. Returns reason.
(define (advance-to! target-n)
  (set-stage! target-n)
  (let ((stage (current-stage)))
    (apply-stage-effects! stage)
    (or (table-ref stage 'say) "")))

;; intent application: the ONLY place quest state changes.
;; returns (status . reason); status in (accepted rejected ignored)
;; Reason text is quest data (data/quests.scm reasons), so the mechanism HUD
;; stays script-agnostic.
(define (apply-intent intent)
  (let ((stage (current-stage)))
    (cond ((eq? intent 'accept)
           (cond ((eq? *quest-state* 'not-offered)
                  (let ((reason (advance-to! (table-ref stage 'on-accept))))
                    (cons 'accepted (if (string=? reason "") (quest-reason 'accept-ok) reason))))
                 ((eq? *quest-state* 'accepted) (cons 'ignored (quest-reason 'accept-dup)))
                 ((eq? *quest-state* 'completed) (cons 'rejected (quest-reason 'accept-done)))
                 (else (cons 'ignored ""))))
          ((eq? intent 'give)
           (cond ((eq? *quest-state* 'accepted)
                  (cond ((<= (ore-carried) 0) (cons 'rejected (quest-reason 'give-empty)))
                        (else
                          (let* ((obj-id (table-ref stage 'objective))
                                 (need (objective-need obj-id))
                                 (remaining (- need *delivered*))
                                 (n (min (ore-carried) remaining)))
                            (bag-remove! 'item/material/ore n)
                            (set! *delivered* (+ *delivered* n))
                            (if (>= *delivered* need)
                                (let ((reason (advance-to! (table-ref stage 'on-give-complete))))
                                  (cons 'accepted reason))
                                (cons 'accepted
                                  (string-fill (quest-reason 'give-partial)
                                    (list (cons "{n}" (number->string n))
                                          (cons "{delivered}" (number->string *delivered*))
                                          (cons "{need}" (number->string need))))))))))
                 ((eq? *quest-state* 'not-offered) (cons 'rejected (quest-reason 'give-not-accepted)))
                 ((eq? *quest-state* 'completed)   (cons 'rejected (quest-reason 'give-done)))
                 (else (cons 'ignored ""))))
          (else (cons 'ignored (quest-reason 'idle))))))

(define (verdict-hint status)
  (table-ref (quest-field 'hints (table)) status ""))
