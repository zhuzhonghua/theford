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
;;   scene     Godot scene path ("scenes/xxx.tscn") for this map
;;   anchors   list of semantic location names NPC schedules and quests use
;;   portals   list of tables (id to at label): id, target map id,
;;             "map:anchor" where the player lands, display label
;;   npcs      npc ids that can appear on this map
;;
;; The active map is runtime state (*current-map*); portals only name their
;; target, Godot owns every pixel.
;;
;; Data DSL: `table` (util.scm). Lists keep their order and stay plain lists.

(require "game.util")

(define *maps*
  (table
    (village
      (name = "渡口村")
      (zone = "peaceful")
      (music = "village")
      (scene = "scenes/world.tscn")
      (anchors = '("herb-garden" "apothecary-stand" "herb-1" "herb-2" "herb-3" "herb-4" "herb-5" "herb-6"
                   "inn" "inn-yard" "riverbank" "village-square"
                   "smith-home" "apothecary-home" "innkeeper-home" "smithy-door"))
      (portals = (list
                   (table (id = 'to-smithy) (to = 'smithy)
                          (at = "smithy:door") (label = "铁匠铺"))))
      (npcs = '("smith" "apothecary" "innkeeper")))
    (smithy
      (name = "铁匠铺")
      (zone = "peaceful")
      (music = "village")
      (scene = "scenes/smithy.tscn")
      (anchors = '("door" "forge" "smith-stand"))
      (portals = (list
                   (table (id = 'to-village) (to = 'village)
                          (at = "village:smithy-door") (label = "渡口村"))))
      (npcs = '("smith")))))

;; The map the player is currently on. Starts in the village; walking into a
;; portal calls game:enter-portal which flips this and tells Godot where to go.
(define *current-map* 'village)

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

;; (map-npcs id) — list of npc ids that can appear on this map, or '().
(define (map-npcs id)
  (let ((m (map-get id)))
    (if m (table-ref m 'npcs '()) '())))

;; (map-scene id) — Godot scene path for the map, or #f.
(define (map-scene id)
  (let ((m (map-get id)))
    (if m (table-ref m 'scene #f) #f)))

;; (map-music id) — music key for the map, or #f.
(define (map-music id)
  (let ((m (map-get id)))
    (if m (table-ref m 'music #f) #f)))

;; (map-portal id portal-id) — the portal table on map `id` keyed by its id,
;; or #f. `portal-id` is a symbol.
(define (map-portal id portal-id)
  (let loop ((ps (map-portals id)))
    (cond ((null? ps) #f)
          ((eq? (table-ref (car ps) 'id) portal-id) (car ps))
          (else (loop (cdr ps))))))

;; (game:map-anchors) — anchor names of the *current* map, for the Godot side
;; to verify that every Marker2D it authored has a matching semantic name.
(define (game:map-anchors)
  (map-anchors *current-map*))

;; (game:current-map) — id of the map the player is on (a string).
(define (game:current-map)
  (symbol->string *current-map*))

;; Bridge entry points: Godot passes map ids as strings, convert to the symbols
;; the tables are keyed with (same convention as game:catalog-music).
(define (game:map-scene id) (map-scene (string->symbol id)))
(define (game:map-music id) (map-music (string->symbol id)))

;; (game:enter-portal portal-id) — the player walked into `portal-id` on the
;; current map. Resolve the target, flip *current-map*, and return
;; (target-map target-anchor label). Godot switches the scene and places the
;; player at the target anchor. `portal-id` arrives as a string.
(define (game:enter-portal portal-id)
  (let ((p (map-portal *current-map* (string->symbol portal-id))))
    (if p
        (let ((to (table-ref p 'to))
              (at (table-ref p 'at ""))
              (label (table-ref p 'label "")))
          (set! *current-map* to)
          (list (symbol->string to) at label))
        (begin
          (display "[portal] unknown portal on ")
          (display *current-map*)
          (display ": ")
          (display portal-id)
          (newline)
          '()))))

;; (game:debug-map) — anchors and portal labels for the current map, plus the
;; list of all registered maps, for smoke tests.
(define (game:debug-map)
  (list (cons 'current (symbol->string *current-map*))
        (cons 'anchors (map-anchors *current-map*))
        (cons 'portals (map (lambda (p) (table-ref p 'label))
                            (map-portals *current-map*)))))
