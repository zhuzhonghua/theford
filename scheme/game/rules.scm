;; rules.scm — event rules: host selector, condition tree, effect list.
;;
;; An event is (kind host actor instrument target params). The engine keeps the
;; most specific matching rule whose host and kind fit, walks its condition
;; tree to a leaf, and runs the effects found there. A leaf of `inherit` falls
;; through to the next most specific candidate; a `do` list of effects runs and
;; stops the search — the rule has decided.
;;
;; Rule data lives in data/rules.scm. Shape (one row per rule id):
;;
;;   (glade/axe
;;     (host = (table (tags = '("tool:axe"))))
;;     (on = "act/use")
;;     (tree = '(if (same actor target)
;;                  inherit
;;                  (do (emit (impulse strike) (to target)
;;                            (params (power power)))))))
;;
;; Conditions: (if c then else), (all c ...), (any c ...), (not c),
;; (same role role), (param key value), (prop role key value),
;; (has role tag), (type role type-id), (fact key expected).
;; A `fact` condition reads the story's fact bag through the same comparator a
;; beat's `when.facts` uses, so rules and story share one truth source.
;;
;; Effects (kept to the subset Phase 5 needs):
;;   (emit (impulse strike) (to role) (params (power power))) — hurt the target,
;;          then fire threshold/cross "broken" when hp runs out
;;   (transform (into type-id))       — host becomes another type (stage-aware)
;;   (spawn (type type-id) (at role) (count n))
;;   (vfx (fx name))
;;   (log (text s))                   — s may be (prop role key)/(param key)
;;   (open)                           — host container toggles its open state
;;   (despawn)                        — host dies: leave the registry (Godot frees its node)
;;
;; Effects are returned as plain data for Godot:
;;   ("hit" id power hp) ("transform" id type) ("spawn" type at-id)
;;   ("vfx" id fx) ("log" text) ("container" id "open"|"closed")
;;   ("despawn" id)
;; Nothing here decides presentation; Godot renders the list.

(require "game.util")
(require "game.entities")
(require "game.inventory")
(require "game.data.types")
(require "game.time")
(require "game.data.rules")
(require "game.story")

;; ---- registry --------------------------------------------------------------

(define *rules* '())   ; (id kind host tree) most recently built order irrelevant

;; Built from *rule-data*; data/rules.scm calls this after defining the table,
;; and game:reload calls it again after the data module is re-read.
(define (rebuild-rules!)
  (set! *rules* '())
  (hash-table-for-each
    (lambda (id row)
      (set! *rules*
            (cons (list id
                        (table-ref row 'on "act/use")
                        (table-ref row 'host (table))
                        (table-ref row 'tree 'inherit))
                  *rules*)))
    *rule-data*)
  (length *rules*))

;; ---- host selector ---------------------------------------------------------

(define (match-selector sel id)
  (cond
    ((not id) #f)
    (else
      (let ((sel-type (table-ref sel 'type #f))
            (sel-id (table-ref sel 'id #f))
            (sel-tags (table-ref sel 'tags '()))
            (not-tags (table-ref sel 'notTags '())))
        (and (or (not sel-type) (is-a (entity-type id) sel-type))
             (or (not sel-id) (eq? id sel-id))
             (every? (lambda (t) (entity-has-tag? id t)) sel-tags)
             (not (any? (lambda (t) (entity-has-tag? id t)) not-tags)))))))

;; ---- matching and specificity ---------------------------------------------

;; A rule on "act" also answers "act/use"; a rule on "act/use" does not answer
;; the broader "act".
(define (kind-covers rule-on event-kind)
  (or (string=? rule-on event-kind)
      (string-prefix? (string-append rule-on "/") event-kind)))

(define (slash-count s)
  (let loop ((i 0) (n 0))
    (if (>= i (string-length s))
        n
        (loop (+ i 1)
              (if (char=? (string-ref s i) #\/) (+ n 1) n)))))

;; Specificity: deeper kind, deeper host type, and explicit tags all win.
(define (spec-of r)
  (let* ((on (cadr r))
         (host (caddr r))
         (type (table-ref host 'type #f))
         (tags (table-ref host 'tags '())))
    (+ (* 100 (slash-count on))
       (if type (* 10 (+ 1 (slash-count (symbol->string type)))) 0)
       (length tags))))

(define (insert-rule r sorted)
  (cond ((null? sorted) (list r))
        ((> (spec-of r) (spec-of (car sorted))) (cons r sorted))
        (else (cons (car sorted) (insert-rule r (cdr sorted))))))

(define (sort-rules rules)
  (if (null? rules)
      '()
      (insert-rule (car rules) (sort-rules (cdr rules)))))

(define (candidates kind host-id)
  (sort-rules
    (let loop ((rs *rules*) (out '()))
      (cond ((null? rs) out)
            ((and (kind-covers (cadr (car rs)) kind)
                  (match-selector (caddr (car rs)) host-id))
             (loop (cdr rs) (cons (car rs) out)))
            (else (loop (cdr rs) out))))))

;; ---- roles -----------------------------------------------------------------

(define (make-roles host actor instrument target)
  (list (cons 'host host)
        (cons 'actor actor)
        (cons 'instrument instrument)
        (cons 'target target)))

(define (role-value roles name)
  (let ((pair (assq name roles)))
    (if pair (cdr pair) #f)))

;; ---- conditions ------------------------------------------------------------

(define (eval-cond c roles params)
  (cond
    ((eq? c #t) #t)
    ((eq? c #f) #f)
    ((not (pair? c))
     (error (string-append "unknown rule condition: " (symbol->string c))))
    (else
      (let ((tag (car c)))
        (cond
          ((eq? tag 'all)
           (all-conds (lambda (x) (eval-cond x roles params)) (cdr c)))
          ((eq? tag 'any)
           (any-conds (lambda (x) (eval-cond x roles params)) (cdr c)))
          ((eq? tag 'not)
           (not (eval-cond (cadr c) roles params)))
          ((eq? tag 'same)
           (let ((a (role-value roles (cadr c)))
                 (b (role-value roles (caddr c))))
             (and a b (eq? a b))))
          ((eq? tag 'param)
           (let ((v (alist-get params (cadr c)))
                 (want (caddr c)))
             (and v (equal? v want))))
          ((eq? tag 'prop)
           (let ((id (role-value roles (cadr c))))
             (and id (equal? (entity-prop id (caddr c)) (cadddr c)))))
          ((eq? tag 'has)
           (let ((id (role-value roles (cadr c))))
             (and id (entity-has-tag? id (caddr c)))))
          ((eq? tag 'type)
           (let ((id (role-value roles (cadr c))))
             (and id (is-a (entity-type id) (caddr c)))))
          ((eq? tag 'fact)
           (story:cmp (story:fact-for-compare (cadr c)) (caddr c)))
          (else
           (error (string-append "unknown rule condition: "
                                 (symbol->string tag)))))))))

;; ---- tree walk -------------------------------------------------------------

;; Returns 'inherit, #f, or a (do effect ...) list.
(define (walk-tree tree roles params)
  (cond
    ((null? tree) 'inherit)
    ((eq? tree 'inherit) 'inherit)
    ((eq? tree #f) #f)
    ((not (pair? tree))
     (error (string-append "unknown rule tree: " (symbol->string tree))))
    ((eq? (car tree) 'do) tree)
    ((eq? (car tree) 'if)
     (if (eval-cond (cadr tree) roles params)
         (walk-tree (caddr tree) roles params)
         (if (null? (cdddr tree))
             #f
             (walk-tree (cadddr tree) roles params))))
    (else
     (error (string-append "unknown rule tree head: "
                           (symbol->string (car tree)))))))

;; ---- dispatch --------------------------------------------------------------

(define *fire-effects* '())
(define *pending-effects* '())
(define *depth* 0)

;; Top entry: one event, effects returned to the caller.
(define (fire kind roles params)
  (set! *fire-effects* '())
  (dispatch kind roles params)
  (reverse *fire-effects*))

;; Recursive entry used by effects (an axe emits a strike on its target). The
;; accumulator is shared, so nested threshold effects keep event order.
(define (dispatch kind roles params)
  (when (>= *depth* 16)
    (error "rule recursion too deep"))
  (set! *depth* (+ *depth* 1))
  (let loop ((rs (candidates kind (role-value roles 'host))))
    (when (pair? rs)
      (let ((leaf (walk-tree (cadddr (car rs)) roles params)))
        (if (and (pair? leaf) (eq? (car leaf) 'do))
            (run-effects (cdr leaf) roles params)
            (loop (cdr rs))))))
  (set! *depth* (- *depth* 1)))

;; ---- effects ---------------------------------------------------------------

;; Read the first value after `key` in an effect's argument list. Effects are
;; written as (op (key value) ...), so `args` is the raw list of pairs.
(define (arg1 args key default)
  (let ((hit (assq key args)))
    (if (and hit (pair? (cdr hit))) (cadr hit) default)))

;; `(params (power power) ...)` keeps every pair; unlike an ordinary argument it
;; may carry more than one.
(define (param-alist args)
  (let ((hit (assq 'params args)))
    (if hit (cdr hit) '())))

(define (resolve-operand v params default)
  (cond ((number? v) v)
        ((string? v) v)
        ((symbol? v)
         (let ((p (alist-get params v)))
           (if (number? p) p default)))
        ((and (pair? v) (eq? (car v) 'param))
         (let ((p (alist-get params (cadr v))))
           (if p p default)))
        (else default)))

;; A text operand: a literal, (prop role key), or (param key).
(define (resolve-value v roles params)
  (cond ((string? v) v)
        ((number? v) (number->string v))
        ((symbol? v) (symbol->string v))
        ((pair? v)
         (cond ((eq? (car v) 'prop)
                (let ((id (role-value roles (cadr v))))
                  (if id
                      (let ((val (entity-prop id (caddr v))))
                        (if val (resolve-value val roles params) ""))
                      "")))
               ((eq? (car v) 'param)
                (let ((val (alist-get params (cadr v))))
                  (if val (resolve-value val roles params) "")))
               (else "")))
        (else "")))

(define (run-effects effects roles params)
  (for-each (lambda (eff) (run-effect eff roles params)) effects))

(define (run-effect eff roles params)
  (let ((op (car eff))
        (args (cdr eff)))
    (cond ((eq? op 'emit) (do-emit args roles params))
          ((eq? op 'transform) (do-transform args roles))
          ((eq? op 'spawn) (do-spawn args roles params))
          ((eq? op 'vfx) (do-vfx args roles))
          ((eq? op 'log) (do-log args roles params))
          ((eq? op 'open) (do-open args roles))
          ((eq? op 'despawn) (do-despawn args roles))
          (else
           (error (string-append "unknown effect op: "
                                 (symbol->string op)))))))

(define (emit-param args params key default)
  (let ((spec (assq key (param-alist args))))
    (if spec (resolve-operand (cadr spec) params default) default)))

(define (do-emit args roles params)
  (let ((impulse (arg1 args 'impulse #f))
        (to (role-value roles (arg1 args 'to #f)))
        (power (emit-param args params 'power 1)))
    (when to
      (cond
        ((eq? impulse 'strike)
         (entity-add-hp! to (- power))
         (push-effect "hit" to power (entity-hp to))
         (when (<= (entity-hp to) 0)
           (dispatch "threshold/cross"
                     (make-roles to
                                 (role-value roles 'actor)
                                 (role-value roles 'instrument)
                                 #f)
                     (list (cons 'name "broken")))))
        (else
         (error (string-append "unknown impulse: "
                               (symbol->string impulse))))))))

(define (do-transform args roles)
  (let ((id (role-value roles 'host))
        (into (arg1 args 'into #f)))
    (when (and id into)
      (entity-transform-type! id into)
      (push-effect "transform" id into)
      ;; A type with a stage (a stump) grows back later; the tick hook hands
      ;; the event back to this module.
      (let ((stage (type-stage into)))
        (when stage
          (let ((next (table-ref stage 'into #f))
                (lasts (table-ref stage 'lasts 0)))
            (when next
              (entity-set-prop! id 'regrow-at (+ *tick* lasts))
              (entity-set-prop! id 'regrow-into next))))))))

(define (do-spawn args roles params)
  (let* ((type (arg1 args 'type #f))
         (at (role-value roles (arg1 args 'at #f)))
         (raw-count (arg1 args 'count #f))
         (count (if raw-count (resolve-operand raw-count params 1) 1)))
    (when (and at type)
      (let loop ((i 0))
        (when (< i count)
          (push-effect "spawn" type at)
          (loop (+ i 1)))))))

(define (do-vfx args roles)
  (let ((id (role-value roles 'host))
        (fx (arg1 args 'fx #f)))
    (when (and id fx)
      (push-effect "vfx" id fx))))

(define (do-log args roles params)
  (let ((text (resolve-value (arg1 args 'text "") roles params)))
    (when (not (string=? text ""))
      (push-effect "log" text))))

;; Toggle a container's open state. The contents stay put: the shell shows a
;; transfer panel for the host and moves stacks through game:transfer.
(define (do-open args roles)
  (let ((host (role-value roles 'host)))
    (when host
      (if (entity-prop host 'open)
          (begin
            (entity-remove-prop! host 'open)
            (push-effect "container" host "closed"))
          (begin
            (entity-set-prop! host 'open #t)
            (push-effect "container" host "open"))))))

;; A defeated creature leaves the registry; the shell frees its node on the
;; effect. Loot is spawned by the same rule before/after this, so the drop
;; survives even though the host is gone.
(define (do-despawn args roles)
  (let ((host (role-value roles 'host)))
    (when host
      (entity-destroy! host)
      (push-effect "despawn" host))))

;; ---- effect tuples ---------------------------------------------------------

(define (marshal v)
  (cond ((symbol? v) (symbol->string v))
        ((pair? v) (map marshal v))
        (else v)))

(define (push-effect . parts)
  (set! *fire-effects* (cons (map marshal parts) *fire-effects*)))

(define (queue-effect . parts)
  (set! *pending-effects* (cons (map marshal parts) *pending-effects*)))

;; Story beats queue their scene commands here instead of owning a second queue;
;; the shell drains them together with timed rule effects.
(set! *story-effect-sink* queue-effect)

;; Effects discovered while ticking (a stump growing back) are pulled by the
;; shell on its next poll.
(define (game:drain-effects)
  (let ((out (reverse *pending-effects*)))
    (set! *pending-effects* '())
    out))

(define (reset-effects!)
  (set! *fire-effects* '())
  (set! *pending-effects* '()))

;; ---- stages ----------------------------------------------------------------

;; Called by time.scm after the tick advances. A stage timer is the only rule
;; event that originates outside an input.
(define (rules-tick!)
  (for-each
    (lambda (id)
      (let ((deadline (entity-prop id 'regrow-at)))
        (when (and (number? deadline) (>= *tick* deadline))
          (let ((into (entity-prop id 'regrow-into)))
            (when into
              (entity-transform-type! id into)
              (entity-remove-prop! id 'regrow-at)
              (entity-remove-prop! id 'regrow-into)
              (queue-effect "transform" id into)
              (queue-effect "vfx" id "leaves"))))))
    (entity-ids)))

;; ---- bridge entries --------------------------------------------------------

;; F: use whatever tool is carried on `target`. With no tool the actor's own
;; hands are the host, and the axe rule cannot match — the verification for
;; "no axe, no effect" is the absence of a matching rule, not a special case.
(define (game:use actor target)
  (let* ((actor (string->symbol actor))
         (target (string->symbol target))
         (inst (held-tool))
         (power (if inst (type-prop inst 'power 1) 1)))
    (fire "act/use"
          (make-roles (if inst inst actor) actor inst target)
          (list (cons 'power power)))))

;; E: the active verb on a thing. Rules decide what "handle" means for a sign
;; or a chest.
(define (game:handle actor target)
  (let ((actor (string->symbol actor))
        (target (string->symbol target)))
    (fire "impulse/handle"
          (make-roles target actor #f target)
          '())))

;; Debug entry for the rule engine: fires an arbitrary event and reports both
;; the candidate rule ids and the effects.
(define (game:debug-fire kind actor inst target params)
  (let* ((actor-id (string->symbol actor))
         (inst-id (if (string=? inst "") #f (string->symbol inst)))
         (target-id (string->symbol target))
         (roles (make-roles (if inst-id inst-id actor-id)
                            actor-id inst-id target-id)))
    (list (map car (candidates kind (role-value roles 'host)))
          (fire kind roles (pairs->alist params)))))

(define (game:debug-rules)
  (map car *rules*))

(rebuild-rules!)
;; Stage timers (a stump growing back) are checked once per tick, after the
;; clock has advanced.
(add-tick-hook! rules-tick!)
