;; combat.scm — blows, health and the decisions a creature makes.
;;
;; The rule engine (rules.scm) decides *what* a blow does: it lowers the target's
;; hp through `entity-add-hp!`, emits a "hit" effect and fires threshold/cross
;; when something dies. This module holds the two pieces that are specific to
;; creatures and to the player:
;;
;;   game:creature-bite creature target — a nearby creature decides to bite;
;;       the power comes from its type's `atk` prop and the blow is handed to
;;       the same rule path a tool swing uses.
;;   game:hp — the player's health as (hp max-hp down?), read into Godot's
;;       snapshot so the HUD can draw hearts and the shell can show Game Over.
;;   game:debug-hurt n — deterministic damage for acceptance/GM only.
;;
;; The player is an ordinary entity named `player` in the registry. Keeping its
;; hp there means a bite needs no special case in the rule engine: it is just a
;; strike whose target happens to be the player. Map travel preserves that hp
;; (see entities.scm); a reload clears the registry and starts at full health.

(require "game.util")
(require "game.entities")
(require "game.rules")

(define player-id 'player)

(define (player-hp)
  ;; During a hot reload the registry is cleared before Godot re-registers the
  ;; player. A reply in that window must report a healthy boot state, not 0 —
  ;; otherwise the shell briefly shows Game Over after a plain F5.
  (let ((e (entity-get player-id)))
    (if e
        (let ((hp (entity-hp player-id)))
          (if (number? hp) hp (player-max-hp)))
        (player-max-hp))))

(define (player-max-hp)
  (type-hp 'actor/person/player))

(define (player-down?)
  (<= (player-hp) 0))

;; (hp max-hp down?) — one reply feeds the hearts HUD and the death check.
(define (game:hp)
  (list (player-hp) (player-max-hp) (if (player-down?) #t #f)))

;; A creature's attack power: an instance prop overrides the type default.
(define (creature-atk creature)
  (let ((v (entity-prop creature 'atk)))
    (if (number? v) v (type-prop (entity-type creature) 'atk 1))))

;; A bite is an impulse with power, exactly like a swing of an axe — only the
;; event kind and the host differ. A downed player cannot be bitten further.
(define (game:creature-bite creature target)
  (let ((creature (string->symbol creature))
        (target (string->symbol target)))
    (if (player-down?)
        '()
        (fire "impulse/bite"
              (make-roles creature creature creature target)
              (list (cons 'power (creature-atk creature)))))))

;; Debug/GM damage: apply a blow straight to the player and return the same
;; effect tuple a rule would emit, so the shell renders it through one path.
(define (game:debug-hurt n)
  (let* ((amount (abs n))
         (hp (begin (entity-add-hp! player-id (- amount))
                    (entity-hp player-id))))
    (list (list "hit" "player" amount hp))))

;; Restore full health without an item — the deterministic twin of a restart
;; for GM/accepted-play setup.
(define (game:debug-heal)
  (entity-set-hp! player-id (player-max-hp))
  (player-hp))
