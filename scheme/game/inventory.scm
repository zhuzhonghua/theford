;; inventory.scm — the player's bag, minimal form for Phase 5.
;;
;; At this stage the bag is one ordered alist of (type . count). It exists so
;; a chest can hand over a tool and the use verb can ask "is a tool carried?".
;; Phase 6 replaces it with item stacks, a capacity limit and a UI; nothing
;; else in the engine should read *bag* directly.
;;
;; The ore counter used by the smith quest stays in quest.scm until that
;; conversion.

(require "game.util")
(require "game.data.types")

(define *bag* '())  ; ((type-symbol . count) ...)

(define (bag-add! type n)
  (let ((have (bag-count type)))
    (set! *bag* (alist-put *bag* type (+ have n)))))

(define (bag-count type)
  (let ((n (alist-get *bag* type)))
    (if n n 0)))

(define (bag-empty!)
  (set! *bag* '()))

;; First carried type that has `tag`, or #f. Phase 5 only needs "a tool is in
;; the bag"; equipping (Phase 6) will pick which one is in hand.
(define (bag-find-tag tag)
  (let loop ((types (map car *bag*)))
    (cond ((null? types) #f)
          ((type-has-tag? (car types) tag) (car types))
          (else (loop (cdr types))))))

(define (held-tool)
  (bag-find-tag "tool:axe"))

;; Rows for the HUD: ((type-string count display-name) ...).
(define (bag-rows)
  (map (lambda (kv)
         (list (symbol->string (car kv)) (cdr kv)
               (type-name (car kv))))
       *bag*))

;; Bridge view: (rows held-type-string held-name). Godot uses the held tool to
;; show the F verb hint; the rows feed the HUD bag line.
(define (game:bag)
  (let ((held (held-tool)))
    (list (bag-rows)
          (if held (symbol->string held) "")
          (if held (type-name held) ""))))
