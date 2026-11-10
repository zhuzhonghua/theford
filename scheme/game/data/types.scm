;; types.scm — the is-a hierarchy of things in the world.
;;
;; Type ids are slash paths (item/tool/axe, as symbols), so the hierarchy is
;; encoded in the id itself. `is-a` is therefore a prefix check on the path: a
;; type is-a its ancestor when the ancestor is the type itself or a strict
;; prefix followed by "/".
;;
;; Each type carries default `props`, `tags`, and an optional `sprite` /
;; `solid`. Inheritance (merging props/tags down the chain) is left for the
;; rule/engine phases; this file only defines the nodes and answers is-a.
;;
;; Data DSL: `table` (util.scm); `props` nests another table.

(require "game.util")

;; Type registry: id -> table of (name tags props sprite solid).
(define *types*
  (table
    (actor/person/villager
      (name = "villager")
      (tags = '("faction:folk")))
    (actor/creature/slime
      (name = "slime")
      (tags = '("slime" "faction:wild"))
      (sprite = "creature:slime")
      (props = (table
                 (hp = 8)
                 (maxHp = 8)
                 (atk = 1)
                 (speed = 7))))
    (item/tool
      (name = "tool")
      (tags = '("tool")))
    (item/tool/axe
      (name = "Axe")
      (tags = '("tool:axe"))
      (sprite = "item:axe")
      (props = (table
                 (power = 3))))
    (item/material
      (name = "material")
      (tags = '("material")))
    (item/material/ore
      (name = "铁矿石")
      (tags = '("ore" "material:iron"))
      (sprite = "item:ore")
      (props = (table
                 (material = "iron"))))
    (item/material/log
      (name = "Log")
      (tags = '("wooden" "flammable"))
      (sprite = "item:log")
      (props = (table
                 (material = "wood"))))
    (item/material/stone
      (name = "Stone")
      (tags = '("stone"))
      (sprite = "item:stone")
      (props = (table
                 (material = "stone"))))
    (item/material/gel
      (name = "Slime Gel")
      (tags = '("gelatinous"))
      (sprite = "item:gel"))
    (fixture/container/chest
      (name = "chest")
      (tags = '("wooden" "flammable"))
      (sprite = "fixture:chest")
      (props = (table
                 (capacity = 8))))
    (fixture/sign
      (name = "sign")
      (tags = '("wooden" "readable"))
      (solid = #t)
      (sprite = "fixture:sign")
      (props = (table
                 (handsRange = 2))))
    (fixture/furniture
      (name = "furniture")
      (tags = '("wooden"))
      (solid = #t))
    (fixture/furniture/bed
      (name = "bed")
      (tags = '("cloth"))
      (solid = #f)
      (sprite = "fixture:bed")
      (props = (table
                 (handsRange = 0))))
    (fixture/furniture/table
      (name = "table")
      (tags = '("surface"))
      (sprite = "fixture:table"))))

;; (type-get id) — the table for a registered type, or #f. `id` is a symbol.
(define (type-get id)
  (table-ref *types* id))

;; (is-a type ancestor) — true when `ancestor` is `type` itself or a strict
;; path prefix (i.e. an ancestor node). Both ids are symbols.
;; Uses string-index from util.scm; a hit at position 0 means prefix.
(define (is-a type ancestor)
  (or (eq? type ancestor)
      (equal? (string-index (symbol->string type)
                            (string-append (symbol->string ancestor) "/"))
              0)))

;; (game:debug-is-a type ancestor) — bridge-visible is-a for the 1.4 smoke
;; test. Ids arrive from GDScript as strings; convert once here.
;;   (game:debug-is-a "item/material/ore" "item/material") → #t
(define (game:debug-is-a type ancestor)
  (is-a (string->symbol type) (string->symbol ancestor)))

;; (game:debug-types) — whole registry, for the data-loading smoke test.
(define (game:debug-types)
  *types*)
