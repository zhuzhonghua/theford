;; world.scm — world-level parameters (data only, no behaviour).
;;
;; Mirrors the shape of openworld's games/starter/game.json:
;;   seed, start{map,x,y}, startHour, params{reach,carry,riseHour}
;; The map itself and NPC placement stay authored in Godot (scenes/world.tscn);
;; Scheme owns these numbers because they drive game logic (time, reach, carry).

(define *world*
  (list (cons 'seed 7)
        ;; Player spawn in world.tscn is (392,280) pixels; TILE is 16 in main.gd.
        (cons 'start (list (cons 'map "village")
                           (cons 'x 24)
                           (cons 'y 17)))
        (cons 'startHour 8)
        (cons 'params (list (cons 'reach 1)
                            (cons 'carry 1)
                            (cons 'riseHour 6)))))

;; (game:debug-world) — whole alist, for the data-loading smoke test.
(define (game:debug-world)
  *world*)
