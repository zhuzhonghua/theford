;; containers.scm — container contents: slot math, transfers, panel view.
;;
;; A container is an entity whose type carries a `capacity` (data/types.scm)
;; and whose per-instance `contents` prop lists what it holds as
;; (type-string count) rows. Opening marks the entity with an `open` prop; the
;; presentation panel asks game:container for a view and moves stacks with
;; game:transfer. Slot rules are the bag's: a piece takes one slot, anything
;; else one per stack-max (see inventory.scm).
;;
;; Nothing here draws anything: rows carry the same shape the bag rows do
;;   (type-string count display-name sprite-key slots)
;; so one grid renderer serves both sides of the panel.

(require "game.util")
(require "game.entities")
(require "game.inventory")
(require "game.data.types")

;; ---- persisted contents -----------------------------------------------------
;;
;; The entity registry is rebuilt from scene data on every map switch, so a
;; chest's `contents` prop alone would reset to its authored state — the axe
;; moved into the bag would appear again, duplicating the item. Container
;; contents are run-time state like the bag: they live here, keyed by entity id,
;; and survive travel. A hot reload clears them so the world returns to start.

(define *containers* '())  ;; (id . ((type-string count) ...)) alist

;; The rows as first authored or last written: ((type-string count) ...).
(define (container-contents id)
  (let ((hit (assoc id *containers*)))
    (if hit
        (cdr hit)
        (let* ((authored (entity-prop id 'contents))
               (rows (if authored authored '())))
          ;; Seed from the scene metadata on first touch; later reads (even
          ;; after a map switch re-registers entities) use the saved copy.
          (set! *containers* (alist-put *containers* id rows))
          rows))))

(define (container-set-contents! id rows)
  (set! *containers* (alist-put *containers* id rows))
  ;; Keep the entity prop in sync for debug views while its map is loaded.
  (entity-set-prop! id 'contents rows))

(define (reset-containers!)
  (set! *containers* '()))

(define (container-count id type)
  (let ((key (symbol->string type)))
    (let loop ((rows (container-contents id)) (n 0))
      (cond ((null? rows) n)
            ((string=? (car (car rows)) key)
             (loop (cdr rows) (+ n (cadr (car rows)))))
            (else (loop (cdr rows) n))))))

(define (container-slots-used id)
  (rows-slots-used (container-contents id)
                   (lambda (row) (string->symbol (car row))) cadr))

;; Per-instance capacity wins over the type's default (the chest's is 8).
(define (container-capacity id)
  (let ((own (entity-prop id 'capacity)))
    (if (number? own)
        own
        (type-prop (entity-type id) 'capacity 0))))

(define (container-fits? id type n)
  (rows-fit? (container-slots-used id) (container-count id type)
             (container-capacity id) type n))

;; ---- mutations --------------------------------------------------------------

;; One row per kind: keep the first row's place, drop duplicates, append a new
;; kind at the end. A count of zero drops the row.
(define (put-row rows key n)
  (let loop ((rs rows) (out '()) (seen #f))
    (cond ((null? rs)
           (reverse (if (or seen (<= n 0))
                        out
                        (cons (list key n) out))))
          ((string=? (car (car rs)) key)
           (loop (cdr rs)
                 (if (or seen (<= n 0)) out (cons (list key n) out))
                 #t))
          (else
           (loop (cdr rs) (cons (car rs) out) seen)))))

;; Add `n` of `type`; the new count, or #f when the container has no room.
(define (container-add! id type n)
  (if (container-fits? id type n)
      (let ((new (+ (container-count id type) n)))
        (container-set-contents! id
                                 (put-row (container-contents id)
                                          (symbol->string type)
                                          new))
        new)
      #f))

;; Remove up to `n` of `type`; the count left.
(define (container-remove! id type n)
  (let ((left (- (container-count id type) n)))
    (let ((left (if (< left 0) 0 left)))
      (container-set-contents! id
                               (put-row (container-contents id)
                                        (symbol->string type)
                                        left))
      left)))

;; ---- view -------------------------------------------------------------------

;; ((type-string count display-name sprite-key slots) ...) — same shape as
;; inventory.scm's bag-rows, so the shell expands both with one rule.
(define (container-rows id)
  (rows-view (container-contents id) car cadr))

;; ---- transfers --------------------------------------------------------------
;;
;; `from` names the side the stack leaves: "chest" moves it into the bag,
;; "bag" moves it into the container. `all` moves the whole stack, otherwise
;; one. What does not fit stays where it was, so a full bag or a full chest
;; never loses an item.

(define (take-from-container id type whole)
  (let loop ((n (if whole (container-count id type) 1)))
    (when (> n 0)
      (if (bag-add! type 1)
          (begin
            (container-remove! id type 1)
            (loop (- n 1)))
          #f))))

(define (put-into-container id type whole)
  (let loop ((n (if whole (bag-count type) 1)))
    (when (> n 0)
      (if (container-add! id type 1)
          (begin
            (bag-remove! type 1)
            (loop (- n 1)))
          #f))))

;; ---- bridge entries ---------------------------------------------------------

;; (game:container id) — the open container's view, or #f when it is closed.
;; (id name capacity slots-used rows)
(define (game:container container)
  (let* ((id (string->symbol container))
         (open (entity-prop id 'open)))
    (if open
        (list container
              (type-name (entity-type id))
              (container-capacity id)
              (container-slots-used id)
              (container-rows id))
        #f)))

;; (game:transfer id from item all) — move a stack between the open container
;; and the bag, then return the fresh container view. #f when the container is
;; not open.
(define (game:transfer container from item all)
  (let* ((id (string->symbol container))
         (type (string->symbol item))
         (whole (if all #t #f)))
    (if (entity-prop id 'open)
        (begin
          (if (string=? from "chest")
              (take-from-container id type whole)
              (put-into-container id type whole))
          (game:container container))
        #f)))

;; (game:close-container id) — the panel was dismissed; the container is no
;; longer open. (The rule engine's `open` effect toggles the same prop.)
(define (game:close-container container)
  (let ((id (string->symbol container)))
    (entity-remove-prop! id 'open)
    #t))

;; ---- save slots -------------------------------------------------------------
(register-save-slot! 'containers (lambda () *containers*)
  (lambda (v) (set! *containers* v)) '())
