;; world.scm — world-level parameters (data only, no behaviour).
;;
;; seed, start{map,x,y}, startHour, params{reach,carry,riseHour}.
;; The map itself and NPC placement stay authored in Godot (scenes/world.tscn);
;; Scheme owns these numbers because they drive game logic (time, reach, carry).
;;
;; Data DSL: `table` (util.scm).

(require "game.util")

(define *world*
  (table
    (seed = 7)
    ;; Player spawn in world.tscn is (392,280) pixels; TILE is 16 in main.gd.
    (start = (table
               (map = "village")
               (x = 24)
               (y = 17)))
    (startHour = 8)
    (params = (table
                (reach = 1)
                (carry = 1)
                (riseHour = 6)))))

;; (game:debug-world) — whole table, for the data-loading smoke test.
(define (game:debug-world)
  *world*)
