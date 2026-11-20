;; inventory.scm — the player's bag: stacks, slots, and the held tool.
;;
;; A stack is one row per carried type, (type . count): things of one kind
;; merge instead of taking a row each. A slot holds at most `stack-max` of a
;; kind; a piece — a tool, a weapon, anything worn — never stacks, one to a
;; slot. The bag has `bag-slots` slots (three rows of ten, the shape the
;; reference bag has). Nothing else in the engine reads *bag* directly:
;; callers add, remove and count, and the bridge asks for a view.

(require "game.util")
(require "game.data.types")

(define stack-max 999)  ; how many of a kind fit one slot
(define bag-slots 30)   ; slots in the bag itself

(define *bag* '())  ; ((type-symbol . count) ...)

;; ---- slots ------------------------------------------------------------------

;; A piece never stacks: a tool, a weapon, anything worn.
(define (piece? type)
  (or (type-has-tag? type "tool")
      (type-has-tag? type "weapon")))

;; Slots one row takes: pieces one each, anything else one per stack-max.
(define (row-slots type n)
  (cond ((<= n 0) 0)
        ((piece? type) n)
        (else (+ 1 (quotient (- n 1) stack-max)))))

(define (bag-slots-used)
  (if (null? *bag*)
      0
      (apply + (map (lambda (row) (row-slots (car row) (cdr row))) *bag*))))

(define (bag-count type)
  (let ((n (alist-get *bag* type)))
    (if n n 0)))

;; Whether `n` more of `type` fit: a stack may still have room in its last
;; slot, so compare the slots used after with the slots used before.
(define (bag-fits? type n)
  (<= (+ (- (bag-slots-used) (row-slots type (bag-count type)))
         (row-slots type (+ (bag-count type) n)))
      bag-slots))

;; ---- mutations --------------------------------------------------------------

;; Add `n` of `type`; the new count, or #f when no slot is left for them.
(define (bag-add! type n)
  (if (bag-fits? type n)
      (let ((have (bag-count type)))
        (set! *bag* (alist-put *bag* type (+ have n)))
        (+ have n))
      #f))

;; Remove up to `n` of `type`; the count left in the bag.
(define (bag-remove! type n)
  (let ((left (- (bag-count type) n)))
    (if (<= left 0)
        (begin
          (set! *bag* (alist-delete type *bag* eq?))
          0)
        (begin
          (set! *bag* (alist-put *bag* type left))
          left))))

(define (bag-empty!)
  (set! *bag* '()))

;; ---- held tool --------------------------------------------------------------

;; First carried type that has `tag`, or #f. The F verb only needs "a tool is
;; carried"; picking which one is in hand is the equipment slot (6.4).
(define (bag-find-tag tag)
  (let loop ((types (map car *bag*)))
    (cond ((null? types) #f)
          ((type-has-tag? (car types) tag) (car types))
          (else (loop (cdr types))))))

(define (held-tool)
  (bag-find-tag "tool:axe"))

;; Rows for the HUD and the bag panel:
;;   ((type-string count display-name sprite-key slots) ...)
;; `sprite-key` is the catalog item key from the type data ("" when absent);
;; the shell resolves it to an icon through game:catalog-item. `slots` is how
;; many grid cells the row takes, so a panel can spill a big stack into the
;; next cell without duplicating the slot rules.
(define (bag-rows)
  (map (lambda (kv)
         (let* ((type (car kv))
                (n (cdr kv))
                (sprite (type-field type 'sprite #f)))
           (list (symbol->string type) n (type-name type)
                 (if sprite sprite "")
                 (row-slots type n))))
       *bag*))

;; ---- bridge entries --------------------------------------------------------

;; (game:take item-type) — put one thing into the bag. #f when no slot is left
;; for it, so the shell can leave it lying in the world.
(define (game:take item)
  (let ((type (string->symbol item)))
    (if (bag-add! type 1) #t #f)))

;; (game:debug-give item-type [n]) — dev-only: put n things straight into the
;; bag (GM console `give`). Returns the new stack count, or #f when full.
(define (game:debug-give item . n)
  (bag-add! (string->symbol item) (if (null? n) 1 (car n))))

;; View: (rows held-type-string held-name slots-used slots-max). Godot uses the
;; held tool for the F verb hint and the slot numbers for the HUD bag line.
(define (game:bag)
  (let ((held (held-tool)))
    (list (bag-rows)
          (if held (symbol->string held) "")
          (if held (type-name held) "")
          (bag-slots-used)
          bag-slots)))
