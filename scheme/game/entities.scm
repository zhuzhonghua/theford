;; entities.scm — runtime registry of things the rule engine can act on.
;;
;; Godot owns the nodes, coordinates and sprites. On every map load it scans
;; the scene for interactable things (trees, signs, chests, ...) and sends one
;; flat list through `game:register-entities`:
;;
;;   ((id type (tags ...) ((prop . value) ...)) ...)
;;
;; The ids are strings chosen by Godot (for example "village:tree:12" or
;; "smithy:Chest"). Scheme converts them to symbols and owns only the mutable
;; state that rules change: type, hp and props. No coordinate is stored here.
;;
;; A type id that is not in the registry (a carried item, for instance) is a
;; valid entity view too: its type is the id itself and tags/props fall back to
;; data/types.scm. That is how the axe can be the host of an act/use event
;; without existing as a scene node.

(require "game.util")
(require "game.data.types")

;; id -> (type hp tags props-alist)
(define *entities* '())

;; ---- registration ----------------------------------------------------------

;; rows: id string, type string, tags list of strings, props list of
;; (key-string value) pairs. Godot sends the whole map at once, so the registry
;; is replaced: dormant maps do not keep stale nodes in the live world.
(define (game:register-entities rows)
  (set! *entities* '())
  (for-each (lambda (row)
              (entity-register! (string->symbol (car row))
                                (string->symbol (cadr row))
                                (caddr row)
                                (pairs->alist (cadddr row))))
            rows)
  (length *entities*))

(define (pairs->alist pairs)
  (map (lambda (p) (cons (string->symbol (car p)) (cadr p))) pairs))

(define (entity-register! id type tags props)
  (let ((entry (list type (type-hp type) tags props)))
    (set! *entities* (alist-put *entities* id entry))))

(define (entity-destroy! id)
  (set! *entities* (alist-delete id *entities* eq?)))

;; ---- queries ---------------------------------------------------------------

;; The full entry, or #f. A thing that is not a scene entity still has a view
;; built from its type data (see the header).
(define (entity-get id)
  (assoc id *entities*))

(define (entity-type id)
  (let ((e (entity-get id)))
    (if e (cadr e) id)))

(define (entity-hp id)
  (let ((e (entity-get id)))
    (if e (caddr e) (type-hp id))))

(define (entity-tags id)
  (let ((e (entity-get id)))
    (if e (cadddr e) (type-tags id))))

(define (entity-props id)
  (let ((e (entity-get id)))
    (if e
        (car (cddddr e))
        (let ((p (type-props id)))
          (if p (hash-table->alist p) '())))))

(define (entity-prop id key)
  (alist-get (entity-props id) key))

(define (entity-set-prop! id key value)
  (let ((e (entity-get id)))
    (when e
      (set-car! (cddddr e) (alist-put (car (cddddr e)) key value)))))

(define (entity-remove-prop! id key)
  (let ((e (entity-get id)))
    (when e
      (set-car! (cddddr e) (alist-delete key (car (cddddr e)) eq?)))))

(define (entity-has-tag? id tag)
  (if (member tag (entity-tags id)) #t #f))

;; ---- modifications ---------------------------------------------------------

(define (entity-set-hp! id n)
  (let ((e (entity-get id)))
    (when e (set-car! (cddr e) n))))

(define (entity-add-hp! id delta)
  (entity-set-hp! id (+ (entity-hp id) delta)))

;; Rebuild the entry with the new type's tags and health; props survive (a
;; felled tree keeps whatever the transform wrote, such as its regrow
;; deadline). Regrowing a stump therefore comes back at the tree's full hp.
(define (entity-transform-type! id new-type)
  (let ((e (entity-get id)))
    (when e
      (set! *entities*
            (alist-put *entities* id
                       (list new-type (type-hp new-type) (type-tags new-type)
                             (entity-props id)))))))

(define (entity-ids)
  (map car *entities*))

;; ---- debug -----------------------------------------------------------------

(define (game:entity-ids)
  (map car *entities*))

(define (game:debug-entity id)
  (let ((e (entity-get (string->symbol id))))
    (if e
        ;; entry layout is (id type hp tags props)
        (list (symbol->string (cadr e))      ; type
              (caddr e)                      ; hp
              (cadddr e)                     ; tags
              (map (lambda (kv)
                     (list (symbol->string (car kv)) (cdr kv)))
                   (car (cddddr e))))        ; props
        #f)))

(define (reset-entities!)
  (set! *entities* '()))
