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

;; The hand slot: the type of the equipped tool/weapon, or #f when empty.
;; One slot only — the F verb uses whatever is in it, so equipping decides
;; whether a tool can be swung. The bag still owns the item; this is just which
;; carried piece is "in hand" (the equipment slot).
(define *equipped* #f)

;; ---- slots ------------------------------------------------------------------

;; A piece never stacks: a tool, a weapon, anything worn. Pieces are also the
;; only things that can go in the hand slot. The type paths carry the hierarchy
;; (item/tool/axe), so check is-a as well as the literal tags — a leaf type's
;; own tags need not repeat its parent's ("tool").
(define (piece? type)
  (or (is-a type 'item/tool)
      (is-a type 'item/weapon)
      (type-has-tag? type "tool")
      (type-has-tag? type "weapon")))

(define (equippable? type)
  (piece? type))

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
;; Picking a tool up only puts it in the bag — it is NOT equipped. Equipping is
;; a deliberate act (game:equip / the bag panel's hand slot), so F does nothing
;; until the player actually puts the tool in hand.
(define (bag-add! type n)
  (if (bag-fits? type n)
      (let ((have (bag-count type)))
        (set! *bag* (alist-put *bag* type (+ have n)))
        (+ have n))
      #f))

;; Remove up to `n` of `type`; the count left in the bag. Taking the equipped
;; piece out of the bag (a container transfer, a quest cost) empties the hand
;; slot too — a tool that is nowhere in the bag cannot stay in hand.
(define (bag-remove! type n)
  (let ((left (- (bag-count type) n)))
    (if (<= left 0)
        (begin
          (set! *bag* (alist-delete type *bag* eq?))
          (if (eq? *equipped* type) (set! *equipped* #f))
          0)
        (begin
          (set! *bag* (alist-put *bag* type left))
          left))))

(define (bag-empty!)
  (set! *bag* '())
  (set! *equipped* #f))

;; ---- equipment / held tool --------------------------------------------------

;; The F verb reads the hand slot, not "any tool in the bag": equipping an axe
;; is what makes a chop possible, and taking it off makes the same F do nothing
;; (the no-tool rule simply never matches). The defensive bag-count check keeps
;; the slot honest even if state is poked from a debug console.
(define (held-tool)
  (if (and *equipped* (> (bag-count *equipped*) 0)) *equipped* #f))

;; Put a carried piece into the hand slot. #f when the type is absent or cannot
;; be equipped (materials, fixtures, unknown ids). Swapping replaces the old
;; piece, which stays in the bag.
(define (equip! type)
  (if (and (> (bag-count type) 0) (equippable? type))
      (begin (set! *equipped* type) #t)
      #f))

;; Empty the hand slot. The piece is not consumed — it stays in the bag.
;; Returns the type formerly held (a symbol), or #f when the slot was empty.
(define (unequip!)
  (let ((old *equipped*))
    (set! *equipped* #f)
    old))

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

;; (game:equip item-type) — put a carried tool/weapon in the hand slot.
;; Returns #t on success, #f when the type is absent or not equippable.
(define (game:equip item)
  (equip! (string->symbol item)))

;; (game:unequip) — empty the hand slot; the tool stays in the bag.
;; Returns the type-string formerly held, or "" when the slot was empty.
(define (game:unequip)
  (let ((old (unequip!)))
    (if old (symbol->string old) "")))

;; View: (rows held-type-string held-name slots-used slots-max). `held` is the
;; equipped hand-slot tool ("" when none) — the same value the F verb and its
;; HUD hint use. Godot reads it for the bag panel's gold border and the hint.
(define (game:bag)
  (let ((held (held-tool)))
    (list (bag-rows)
          (if held (symbol->string held) "")
          (if held (type-name held) "")
          (bag-slots-used)
          bag-slots)))
