;; quest.scm — deterministic quest state, delivery counts and dialogue history.
;;
;; This is the only module allowed to change the smith quest: the LLM may
;; narrate a verdict, but `apply-intent` is what actually moves state.

(require "game.util")

;; The smith's quest: not-offered -> accepted -> completed.
;; Ore picked up on the map increments *carried*; handing it over at the
;; smith's moves it to *delivered*. Only the setters below may change state.
(define *quest-state* 'not-offered)
(define *carried* 0)
(define *delivered* 0)

(define *histories* '())   ; ((npc-id . ((speaker . text) ...)) ...) newest first

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

(define *qt-text-not-offered* "任务：未接（找铁匠老王聊聊）")
(define *qt-text-accepted*    "任务：给老王找 3 块铁矿石（河边有矿点）")

(define (quest-text)
  (cond ((eq? *quest-state* 'not-offered) *qt-text-not-offered*)
        ((eq? *quest-state* 'accepted)
         (string-append "任务：给老王找铁矿石（已交 "
           (number->string *delivered*) " / 3，背上还有 "
           (number->string *carried*) " 块）"))
        (else "任务：完成！老王送了你一把铁剑。")))

;; intent application: the ONLY place quest state changes.
;; returns (status . reason); status in (accepted rejected ignored)
(define (apply-intent intent)
  (cond ((eq? intent 'accept)
         (cond ((eq? *quest-state* 'not-offered)
                (begin (set! *quest-state* 'accepted)
                       (cons 'accepted "玩家接受了任务")))
               ((eq? *quest-state* 'accepted) (cons 'ignored "任务已经接过"))
               ((eq? *quest-state* 'completed) (cons 'rejected "任务早已完成"))
               (else (cons 'ignored ""))))
        ((eq? intent 'give)
         (cond ((eq? *quest-state* 'accepted)
                (cond ((<= *carried* 0) (cons 'rejected "玩家背上没有矿石"))
                      (else
                        (let ((n (min *carried* (- 3 *delivered*))))
                          (set! *carried* (- *carried* n))
                          (set! *delivered* (+ *delivered* n))
                          (if (>= *delivered* 3)
                              (begin
                                (set! *quest-state* 'completed)
                                (cons 'accepted (string-append "收下第 3 块矿石，任务完成，赠玩家一把铁剑")))
                              (cons 'accepted (string-append "收下 " (number->string n) " 块矿石（"
                                        (number->string *delivered*) " / 3）")))))))
               ((eq? *quest-state* 'not-offered) (cons 'rejected "任务还没接，不能收矿石"))
               ((eq? *quest-state* 'completed)   (cons 'rejected "任务已完成"))
               (else (cons 'ignored ""))))
        (else (cons 'ignored "闲聊，不动状态"))))

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
