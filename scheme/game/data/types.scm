;; types.scm — the is-a hierarchy of things in the world.
;;
;; Type ids are slash paths ("item/tool/axe"), so the hierarchy is encoded
;; in the id itself. `is-a` is therefore a prefix check on the path: a type
;; is-a its ancestor when the ancestor is the type itself or a strict prefix
;; followed by "/".
;;
;; Each type carries default `props`, `tags`, and an optional `sprite` /
;; `solid`. Inheritance (merging props/tags down the chain) is left for the
;; rule/engine phases; this file only defines the nodes and answers is-a.

(require "game.util")

;; Type registry: id -> alist of (name tags props sprite solid).
(define *types*
  (list
    (cons "actor/person/villager"
      (list (cons 'name "villager")
            (cons 'tags '("faction:folk"))))
    (cons "actor/creature/slime"
      (list (cons 'name "slime")
            (cons 'tags '("slime" "faction:wild"))
            (cons 'sprite "creature:slime")
            (cons 'props (list (cons 'hp 8)
                               (cons 'maxHp 8)
                               (cons 'atk 1)
                               (cons 'speed 7)))))
    (cons "item/tool"
      (list (cons 'name "tool")
            (cons 'tags '("tool"))))
    (cons "item/tool/axe"
      (list (cons 'name "Axe")
            (cons 'tags '("tool:axe"))
            (cons 'sprite "item:axe")
            (cons 'props (list (cons 'power 3)))))
    (cons "item/material"
      (list (cons 'name "material")
            (cons 'tags '("material"))))
    (cons "item/material/ore"
      (list (cons 'name "铁矿石")
            (cons 'tags '("ore" "material:iron"))
            (cons 'sprite "item:ore")
            (cons 'props (list (cons 'material "iron")))))
    (cons "item/material/log"
      (list (cons 'name "Log")
            (cons 'tags '("wooden" "flammable"))
            (cons 'sprite "item:log")
            (cons 'props (list (cons 'material "wood")))))
    (cons "item/material/stone"
      (list (cons 'name "Stone")
            (cons 'tags '("stone"))
            (cons 'sprite "item:stone")
            (cons 'props (list (cons 'material "stone")))))
    (cons "item/material/gel"
      (list (cons 'name "Slime Gel")
            (cons 'tags '("gelatinous"))
            (cons 'sprite "item:gel")))
    (cons "fixture/container/chest"
      (list (cons 'name "chest")
            (cons 'tags '("wooden" "flammable"))
            (cons 'sprite "fixture:chest")
            (cons 'props (list (cons 'capacity 8)))))
    (cons "fixture/sign"
      (list (cons 'name "sign")
            (cons 'tags '("wooden" "readable"))
            (cons 'solid #t)
            (cons 'sprite "fixture:sign")
            (cons 'props (list (cons 'handsRange 2)))))
    (cons "fixture/furniture"
      (list (cons 'name "furniture")
            (cons 'tags '("wooden"))
            (cons 'solid #t)))
    (cons "fixture/furniture/bed"
      (list (cons 'name "bed")
            (cons 'tags '("cloth"))
            (cons 'solid #f)
            (cons 'sprite "fixture:bed")
            (cons 'props (list (cons 'handsRange 0)))))
    (cons "fixture/furniture/table"
      (list (cons 'name "table")
            (cons 'tags '("surface"))
            (cons 'sprite "fixture:table")))))

;; (type-get id) — the alist for a registered type, or #f.
(define (type-get id)
  (alist-get *types* id))

;; (is-a type ancestor) — true when `ancestor` is `type` itself or a
;; strict path prefix (i.e. an ancestor node).
;; Uses string-index from util.scm; a hit at position 0 means prefix.
(define (is-a type ancestor)
  (or (string=? type ancestor)
      (equal? (string-index type (string-append ancestor "/")) 0)))

;; (game:debug-is-a type ancestor) — bridge-visible is-a for the 1.4
;; smoke test: (game:debug-is-a "item/material/ore" "item/material") → #t.
(define (game:debug-is-a type ancestor)
  (is-a type ancestor))

;; (game:debug-types) — whole registry, for the data-loading smoke test.
(define (game:debug-types)
  *types*)
