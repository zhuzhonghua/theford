;; maps.scm — map-level data: names only, no coordinates.
;;
;; Scheme owns the *names* of places (anchors, portals) and which NPCs belong
;; to which map. Coordinates, geometry and collision live in Godot
;; (scenes/*.tscn); when Scheme says "go to smithy" Godot resolves that name
;; to a tile. This keeps a single source of truth for the world layout.
;;
;; Each map is an alist:
;;   name      display name of the map
;;   zone      "peaceful" | "combat" — drives music / threat rules
;;   music     music track key (resolved by Godot's audio layer)
;;   anchors   list of semantic location names NPC schedules and quests use
;;   portals   list of (to at label): target map id, target anchor, display label
;;   npcs      npc ids that spawn on this map

(require "game.util")

(define *maps*
  (list
    (cons "village"
      (list
        (cons 'name "渡口村")
        (cons 'zone "peaceful")
        (cons 'music "village")
        (cons 'anchors '("smithy" "herb-garden" "inn" "riverbank" "village-square"))
        (cons 'portals '())
        (cons 'npcs '("smith" "apothecary" "innkeeper"))))))

;; (map-get id) — the alist for a registered map, or #f.
(define (map-get id)
  (alist-get *maps* id))

;; (map-anchors id) — list of anchor names on the map, or '().
(define (map-anchors id)
  (let ((m (map-get id)))
    (if m (or (alist-get m 'anchors) '()) '())))

;; (map-portals id) — list of portal alists on the map, or '().
(define (map-portals id)
  (let ((m (map-get id)))
    (if m (or (alist-get m 'portals) '()) '())))

;; (map-npcs id) — list of npc ids that spawn on this map, or '().
(define (map-npcs id)
  (let ((m (map-get id)))
    (if m (or (alist-get m 'npcs) '()) '())))

;; (game:debug-map) — anchors and portal labels for the village, for the
;; 1.5 smoke test.
(define (game:debug-map)
  (list (cons 'anchors (map-anchors "village"))
        (cons 'portals (map (lambda (p) (alist-get p 'label)) (map-portals "village")))))
