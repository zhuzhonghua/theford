;; data/rules.scm — rule declarations for Phase 5.
;;
;; Rules are plain data consumed by rules.scm. Each row is keyed by rule id and
;; holds:
;;   on     event kind the rule answers (a deeper kind also answers its
;;          children: a rule on "act" answers "act/use")
;;   host   selector table: type / id / tags / notTags
;;   tree   condition tree ending in `inherit` or (do effect ...)
;;
;; The engine picks the most specific matching rule. See rules.scm for the
;; condition and effect vocabulary.
;;
;; Phase 5 exercises one complete chain (axe → strike → threshold → felled
;; tree) plus the two E-verb fixtures (sign, chest). Adding a rule is a data
;; edit only.
;;
;; Data DSL: `table` (util.scm).

(require "game.util")

(define *rule-data*
  (table
    ;; ---- axe: using it emits a strike on the target ------------------------
    ;; `power` is an event param (the axe's 3 damage). Hitting yourself is a
    ;; no-op; otherwise the strike lands on the target and may cross its hp
    ;; threshold, which is where the fell rule below takes over.
    (glade/axe
      (on = "act/use")
      (host = (table (tags = '("tool:axe"))))
      (tree = '(if (same actor target)
                   inherit
                   (do (emit (impulse strike)
                             (to target)
                             (params (power power)))))))

    ;; ---- fell: a broken tree becomes a stump, two logs, leaves ------------
    ;; threshold/cross is fired by the strike effect with name=broken. The
    ;; transform is stage-aware: a stump declares what it regrows into and
    ;; after how many ticks, so rules.scm records the deadline automatically.
    (glade/fell
      (on = "threshold/cross")
      (host = (table (type = 'fixture/tree)))
      (tree = '(if (param name "broken")
                   (do (transform (into fixture/stump))
                       (spawn (type item/material/log) (at host) (count 2))
                       (vfx (fx "leaves"))
                       (log (text "Timber!")))
                   inherit)))

    ;; ---- sign: E reads the board -----------------------------------------
    ;; The text is per-instance data (props/text) supplied by the map, so the
    ;; same rule works for any number of signs.
    (fixture/sign-read
      (on = "impulse/handle")
      (host = (table (type = 'fixture/sign)))
      (tree = '(do (log (text (prop host text))))))

    ;; ---- chest: E empties the contents into the actor's bag ---------------
    ;; `contents` is per-instance data: a list of (type-string count) pairs.
    ;; Opening once clears it; the rule then reports an empty chest.
    (fixture/chest-open
      (on = "impulse/handle")
      (host = (table (type = 'fixture/container/chest)))
      (tree = '(do (open))))))
