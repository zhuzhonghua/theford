;; maps.scm — map-level data: names only, no coordinates.
;;
;; Scheme owns the *names* of places (anchors, portals) and which NPCs belong
;; to which map. Coordinates, geometry and collision live in Godot
;; (scenes/*.tscn); when Scheme says "go to smithy" Godot resolves that name
;; to a tile. This keeps a single source of truth for the world layout.
;;
;; Each map:
;;   name      display name of the map
;;   zone      "peaceful" | "combat" — drives music / threat rules
;;   music     music track key (resolved by Godot's audio layer)
;;   anchors   list of semantic location names NPC schedules and quests use
;;   portals   list of tables (to at label): target map id, anchor, display label
;;   npcs      npc ids that spawn on this map
;;
;; Data DSL: `table` (util.scm). Lists keep their order and stay plain lists.

(require "game.util")

(define *maps*
  (table
    (village
      (name = "渡口村")
      (zone = "peaceful")
      (music = "village")
      (anchors = '("smithy" "herb-garden" "inn" "riverbank" "village-square"))
      (portals = '())
      (npcs = '("smith" "apothecary" "innkeeper")))))

;; (map-get id) — the table for a registered map, or #f. `id` is a symbol.
(define (map-get id)
  (table-ref *maps* id))

;; (map-anchors id) — list of anchor names on the map, or '().
(define (map-anchors id)
  (let ((m (map-get id)))
    (if m (table-ref m 'anchors '()) '())))

;; (map-portals id) — list of portal tables on the map, or '().
(define (map-portals id)
  (let ((m (map-get id)))
    (if m (table-ref m 'portals '()) '())))

;; (map-npcs id) — list of npc ids that spawn on this map, or '().
(define (map-npcs id)
  (let ((m (map-get id)))
    (if m (table-ref m 'npcs '()) '())))

;; (game:debug-map) — anchors and portal labels for the village, for the
;; 1.5 smoke test.
(define (game:debug-map)
  (list (cons 'anchors (map-anchors 'village))
        (cons 'portals (map (lambda (p) (table-ref p 'label)) (map-portals 'village)))))
