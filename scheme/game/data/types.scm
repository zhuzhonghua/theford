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
    ;; The player is a real entity in the registry so a bite is just a strike
    ;; whose target happens to be "player" — no special case in the rule engine.
    ;; Its hp survives map travel (entities.scm) and resets on a hot reload.
    (actor/person/player
      (name = "你")
      (tags = '("person" "player" "faction:folk"))
      (props = (table
                 (hp = 10)
                 (maxHp = 10))))
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
    (item/material/herb
      (name = "草药")
      (tags = '("herb" "material:herb"))
      (sprite = "item:herb"))
    (item/food/meat
      (name = "干粮")
      (tags = '("food"))
      (sprite = "item:meat"))
    (item/weapon/iron-sword
      (name = "铁剑")
      (tags = '("weapon:sword"))
      (sprite = "item:sword")
      (props = (table
                 (power = 4))))
    (fixture/tree
      (name = "树")
      (tags = '("plant" "tree" "flammable" "wooden" "solid"))
      (solid = #t)
      (props = (table
                 (material = "wood")
                 (maxHp = 6)
                 (hp = 6))))
    (fixture/stump
      (name = "树桩")
      (tags = '("wooden" "flammable"))
      (solid = #f)
      ;; stage: what a transformed thing becomes again, and after how many
      ;; ticks (9600 = 16 game hours, matching the reference terrain data).
      (stage = (table
                  (into = 'fixture/tree)
                  (lasts = 9600)
                  (fx = "leaves"))))
    (fixture/container/chest
      (name = "箱子")
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
    ;; Clues are authored interactables for the three-act story. They carry no
    ;; collision; E on one fires the same handle event as a sign.
    (fixture/clue
      (name = "clue")
      (tags = '("clue" "readable")))
    (fixture/clue/mud
      (name = "河滩泥印")
      (tags = '("clue" "mud")))
    (fixture/clue/rope
      (name = "断缆")
      (tags = '("clue" "rope")))
    (fixture/clue/winch
      (name = "绞盘")
      (tags = '("clue" "rope")))
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

;; Accessors with structural defaults: callers may use a type id that is not
;; registered (the rule engine treats an unregistered id as a leaf type).
(define (type-field id key default)
  (let ((t (type-get id)))
    (if t (table-ref t key default) default)))

(define (type-name id)
  (type-field id 'name (symbol->string id)))

(define (type-tags id)
  (type-field id 'tags '()))

(define (type-has-tag? id tag)
  (if (member tag (type-tags id)) #t #f))

;; Default props as a hash table (or #f).
(define (type-props id)
  (type-field id 'props #f))

(define (type-prop id key default)
  (let ((p (type-props id)))
    (if p (table-ref p key default) default)))

;; A stage table (into/lasts/fx) for things that regrow after a transform.
(define (type-stage id)
  (type-field id 'stage #f))

;; Health of a freshly registered thing, from its type's props.
(define (type-hp id)
  (let ((p (type-props id)))
    (if p
        (or (table-ref p 'hp #f) (table-ref p 'maxHp 0))
        0)))

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
