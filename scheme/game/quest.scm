;; quest.scm — generic quest engine over data/quests.scm.
;;
;; Quest definitions (objectives, stages, dialogue, take/reward) live in
;; data/quests.scm. This module only holds mutable state and applies intents
;; against the current stage's data. It is the only module allowed to change
;; quest state: the LLM may narrate, but `apply-intent` moves state.
;;
;; Public surface (unchanged so talk.scm keeps working):
;;   *quest-state*  symbol: not-offered | accepted | completed
;;   *carried*      ore picked up but not handed in
;;   *delivered*    ore handed to the smith
;;   quest-text     current HUD description
;;   apply-intent   (status . reason) for accept | give | chat
;;   verdict-hint   LLM steering per verdict status
;;   game:take-ore  pickup one ore
;;   game:status    (quest-text carried)

(require "game.util")
(require "game.data.quests")

;; The active quest is the smith-ore chain (only one quest for now).
(define *active-quest* 'smith-ore)

;; Stage numbers map to the legacy state symbols talk.scm still reads.
(define *stage->state*
  (table
    (10 = 'not-offered)
    (20 = 'accepted)
    (100 = 'completed)))

(define (quest-def)
  (table-ref *quests* *active-quest*))

(define (quest-stages)
  (table-ref (quest-def) 'stages '()))

(define (quest-objectives)
  (table-ref (quest-def) 'objectives '()))

(define (current-stage-num)
  *stage*)

(define (current-stage)
  (table-ref (quest-stages) (current-stage-num)))

(define (objective-need obj-id)
  (let ((obj (table-ref (quest-objectives) obj-id)))
    (if obj (table-ref obj 'need 0) 0)))

;; ---- mutable state -----------------------------------------------------------

(define *stage* 10)                  ; current stage number
(define *carried* 0)
(define *delivered* 0)
(define *histories* '())

;; Derive the legacy state symbol from the current stage number.
(define (stage->state n)
  (table-ref *stage->state* n 'not-offered))

(define *quest-state* (stage->state *stage*))

(define (set-stage! n)
  (set! *stage* n)
  (set! *quest-state* (stage->state n)))

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
        "{carried}" (number->string *carried*))
      "{need}" (number->string need))))

(define (quest-text)
  (let ((stage (current-stage)))
    (interpolate-quest-text (or (table-ref stage 'quest-text) ""))))

;; ---- intent application ------------------------------------------------------

;; Apply stage-entry effects: take items from carried, grant rewards.
(define (apply-stage-effects! stage)
  (let ((take (table-ref stage 'take)))
    (when take
      (let ((n (min *carried* (table-ref take 'count 0))))
        (set! *carried* (- *carried* n))
        (set! *delivered* (+ *delivered* n)))))
  ;; reward is recorded (no inventory yet, so just acknowledged).
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
(define (apply-intent intent)
  (let ((stage (current-stage)))
    (cond ((eq? intent 'accept)
           (cond ((eq? *quest-state* 'not-offered)
                  (let ((reason (advance-to! (table-ref stage 'on-accept))))
                    (cons 'accepted (if (string=? reason "") "玩家接受了任务" reason))))
                 ((eq? *quest-state* 'accepted) (cons 'ignored "任务已经接过"))
                 ((eq? *quest-state* 'completed) (cons 'rejected "任务早已完成"))
                 (else (cons 'ignored ""))))
          ((eq? intent 'give)
           (cond ((eq? *quest-state* 'accepted)
                  (cond ((<= *carried* 0) (cons 'rejected "玩家背上没有矿石"))
                        (else
                          (let* ((obj-id (table-ref stage 'objective))
                                 (need (objective-need obj-id))
                                 (remaining (- need *delivered*))
                                 (n (min *carried* remaining)))
                            (set! *carried* (- *carried* n))
                            (set! *delivered* (+ *delivered* n))
                            (if (>= *delivered* need)
                                (let ((reason (advance-to! (table-ref stage 'on-give-complete))))
                                  (cons 'accepted reason))
                                (cons 'accepted
                                  (string-append "收下 " (number->string n) " 块矿石（"
                                    (number->string *delivered*) " / "
                                    (number->string need) "）")))))))
                 ((eq? *quest-state* 'not-offered) (cons 'rejected "任务还没接，不能收矿石"))
                 ((eq? *quest-state* 'completed)   (cons 'rejected "任务已完成"))
                 (else (cons 'ignored ""))))
          (else (cons 'ignored "闲聊，不动状态")))))

(define (verdict-hint status)
  (cond ((eq? status 'accepted) "老王的请求得到了满足，简短回应，语气高兴。")
        ((eq? status 'rejected) "老王必须拒绝，例如：不行，你还没接这活儿呢。")
        (else "只是闲聊，老王正常回应即可。")))

;; ---- pickups and status ------------------------------------------------------

(define (game:take-ore)
  (set! *carried* (+ *carried* 1))
  *carried*)

(define (game:status)
  (list (quest-text) *carried*))
