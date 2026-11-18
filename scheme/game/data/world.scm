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
                (riseHour = 6)))
    ;; Fixed-weather spans; empty means "draw every day from the seed".
    ;; Each span is a table: day + weather, optional from/to hours [from, to).
    ;; Example — a storm on the evening of day 2:
    ;;   (weatherPlan = (list (table (day = 2) (from = 18) (to = 24) (weather = 'storm))))
    (weatherPlan = '())))

;; (game:debug-world) — whole table, for the data-loading smoke test.
(define (game:debug-world)
  *world*)
