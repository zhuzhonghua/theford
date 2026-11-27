;; story.scm — story/fact engine over data/story.scm.
;;
;; The story is a pseudo-entity whose properties are the facts. Beats are
;; evaluated on a slow schedule (every 3 ticks, or when the player reaches a
;; named place) and play at most one per tick, in data order. A beat writes
;; `seen.<id>`, optional facts, and scene commands that travel through the
;; effect bus to the Godot presentation layer. Scheme decides what happens;
;; Godot shows the lines and owns the scene's pacing.
;;
;; Facts and rules conditions are two views of the same store: rules.scm reads
;; them through `story:fact`, and a beat's `when.facts` uses the same `story:cmp`
;; comparison. Protected prefixes cannot be written from the debug boundary.
;;
;; Public surface:
;;   story:fact / story:set-fact! / story:cmp
;;   story:met / story:eligible / story:play!
;;   story-tick!        registered on time.scm's tick hook
;;   story:prompt-line  notable facts folded into the LLM prompt
;;   reset-story!       back to the opening, used by game:reload
;;   game:story-place / game:story-pause / game:story-status / game:story-facts
;;   game:debug-story-beat / game:debug-set-fact

(require "game.util")
(require "game.data.story")
(require "game.time")
(require "game.data.maps")
(require "game.quest")
(require "game.inventory")

;; ---- facts -------------------------------------------------------------------

(define *facts* '())        ; alist: fact-id symbol -> number/string/#t
(define *story-place* "")   ; nearest named anchor the player is at
(define *story-last* "")    ; last beat that played (the `step.last` fact)
(define *story-arrived* #t) ; recompute place-based beats on the next scan
(define *story-paused* #f)  ; a scene panel owns input; hold new beats
(define *story-started* #f) ; the shell opens the start menu before play begins

;; The rule engine installs its effect queue here. Keeping the sink injectable
;; avoids a require cycle: story never needs to know about rules.
(define *story-effect-sink* #f)

(define (story:push-effect! . parts)
  (if *story-effect-sink* (apply *story-effect-sink* parts) #f))

(define (story:protected? key)
  (let ((name (if (symbol? key) (symbol->string key) key)))
    (let loop ((prefixes *protected-facts*))
      (cond ((null? prefixes) #f)
            ((string-prefix? (car prefixes) name) #t)
            (else (loop (cdr prefixes)))))))

;; Internal writes (from a beat or the engine itself) bypass the reserved-prefix
;; guard; the debug boundary does not, so a patch cannot define seen.* or ford.*.
(define (story:set-fact! key val . internal)
  (if (and (null? internal) (story:protected? key))
      (begin
        (display "[story] 拒绝写入受保护 fact：")
        (display key) (newline)
        #f)
      (begin
        (set! *facts* (alist-put *facts* key val))
        #t)))

(define (story:fact key)
  (alist-get *facts* key))

(define (story:fact-for-compare key)
  (let ((v (story:fact key)))
    (if v v 0)))

;; Same comparator the rules condition tree uses: a bare value is equality,
;; a table may ask for eq/ne or a numeric range.
(define (story:cmp v c)
  (if (or (not c) (not (equal? (type c) 'hash-table)))
      (equal? v c)
      (and
        (or (not (hash-table-exists? c 'eq))
            (equal? v (hash-table-ref c 'eq)))
        (or (not (hash-table-exists? c 'ne))
            (not (equal? v (hash-table-ref c 'ne))))
        (or (not (hash-table-exists? c 'gt))
            (and (number? v) (> v (hash-table-ref c 'gt))))
        (or (not (hash-table-exists? c 'gte))
            (and (number? v) (>= v (hash-table-ref c 'gte))))
        (or (not (hash-table-exists? c 'lt))
            (and (number? v) (< v (hash-table-ref c 'lt))))
        (or (not (hash-table-exists? c 'lte))
            (and (number? v) (<= v (hash-table-ref c 'lte)))))))

;; ---- condition vocabulary ----------------------------------------------------

(define (story:carrying? prefix)
  (let loop ((xs *bag*))
    (cond ((null? xs) #f)
          ((string-prefix? prefix (symbol->string (car xs))) #t)
          (else (loop (cdr xs))))))

(define (story:any-quest-accepted?)
  (let loop ((ids (quest-ids)))
    (cond ((null? ids) #f)
          ((eq? (qstate-sym (car ids)) 'accepted) #t)
          (else (loop (cdr ids))))))

;; `when` rows are written as (key value) lists, so the value is the car of
;; what alist-get returns (which is the row's cdr).
(define (story:w cond key)
  (let ((v (alist-get cond key)))
    (if (pair? v) (car v) v)))

(define (story:met cond)
  (let* ((now (clock-at *tick*))
         (day (car now))
         (hour (cadr now))
         (map-v (story:w cond 'map))
         (place-v (story:w cond 'place))
         (day-v (story:w cond 'day))
         (hour-v (story:w cond 'hour))
         (weather-v (story:w cond 'weather))
         (facts-v (story:w cond 'facts))
         (quest-v (story:w cond 'quest))
         (carry-v (story:w cond 'carrying))
         (after-v (story:w cond 'after)))
    (and
      (or (not map-v) (string=? map-v (symbol->string *current-map*)))
      (or (not place-v) (string=? place-v *story-place*))
      (or (not day-v) (>= day day-v))
      (or (not hour-v)
          (let ((from (car hour-v)) (to (cadr hour-v)))
            (if (<= from to)
                (and (>= hour from) (< hour to))
                (or (>= hour from) (< hour to)))))
      (or (not weather-v)
          (if (pair? weather-v)
              (any? (lambda (w) (eq? w (current-weather))) weather-v)
              (eq? weather-v (current-weather))))
      (or (not facts-v)
          (all-conds
            (lambda (p)
              (story:cmp (story:fact-for-compare (car p)) (cadr p)))
            facts-v))
      (or (not quest-v)
          (all-conds
            (lambda (p) (eq? (qstate-sym (car p)) (cadr p)))
            quest-v))
      (or (not carry-v)
          (all-conds
            (lambda (t) (story:carrying? t))
            carry-v))
      (or (not after-v)
          (story:fact-for-compare
            (string->symbol (string-append "seen." after-v)))))))

;; ---- playing a beat ----------------------------------------------------------

(define (story:seen-key id day-based)
  (string->symbol
    (string-append "seen." (symbol->string id)
                   (if day-based ".day" ""))))

(define (story:eligible id d)
  (cond ((table-ref d 'manual #f) #f)
        ((table-ref d 'repeat #f)
         (not (= (story:fact-for-compare (story:seen-key id #t))
                 (car (clock-at *tick*)))))
        ((story:fact (story:seen-key id #f)) #f)
        (else (story:met (table-ref d 'when '())))))

(define (story:play! id d)
  (story:set-fact! (story:seen-key id #f) *tick* #t)
  (if (table-ref d 'repeat #f)
      (story:set-fact! (story:seen-key id #t) (car (clock-at *tick*)) #t))
  (set! *story-last* (symbol->string id))
  (story:set-fact! 'step.last *story-last* #t)
  (for-each
    (lambda (p) (story:set-fact! (car p) (cadr p) #t))
    (table-ref d 'facts '()))
  (let ((script (table-ref d 'script #f)))
    (if script
        (for-each (lambda (cmd) (apply story:push-effect! cmd)) script)
        (let ((say (table-ref d 'say #f)))
          (if say
              (story:push-effect! "scene" ""
                (list (list "旁白" say)))))))
  (set! *story-arrived* #t)
  #t)

(define (story:try-beat id)
  (let ((d (table-ref *steps* id #f)))
    (if d (story:play! id d) #f)))

(define (game:debug-story-beat id)
  (story:try-beat (string->symbol id)))

;; ---- invariants --------------------------------------------------------------

;; `holds` is a small condition vocabulary: `any-quest-accepted` plus the same
;; fact comparison a beat uses. A broken invariant is reported once, folded
;; into an invalid.* fact and given a deterministic fallback line.
(define (story:holds-rows rows)
  (let loop ((xs rows))
    (cond ((null? xs) #t)
          (else
            (let* ((p (car xs))
                   (key (car p))
                   (want (cadr p))
                   (v (cond ((eq? key 'any-quest-accepted)
                             (if (story:any-quest-accepted?) 1 0))
                            (else (story:fact-for-compare key)))))
              (and (story:cmp v want) (loop (cdr xs))))))))

(define (story:invariants!)
  (let loop ((ids (hash-table-keys *invariants*)))
    (if (not (null? ids))
        (let* ((id (car ids))
               (inv (table-ref *invariants* id #f))
               (reported (string->symbol
                           (string-append "invalid." (symbol->string id)))))
          (if (and inv
                   (not (story:fact reported))
                   (story:met (table-ref inv 'when '()))
                   (not (story:holds-rows (table-ref inv 'holds '()))))
              (begin
                (story:set-fact! reported *tick* #t)
                (let ((text (table-ref inv 'fallback "")))
                  (if (string? text)
                      (story:push-effect! "scene" "提示"
                        (list (list "旁白" text)))))))
          (loop (cdr ids))))))

;; ---- scheduling --------------------------------------------------------------

(define (story-tick!)
  ;; No beats (and no invariant nudges) while the start menu is up: otherwise
  ;; the opening cutscene pops behind the menu and vanishes on "new game".
  (when *story-started*
    (when (and (not *story-paused*)
               (or *story-arrived* (= (modulo *tick* 3) 0)))
      (set! *story-arrived* #f)
      (let loop ((ids *story-order*))
        (cond ((null? ids) #f)
              (else
                (let* ((id (car ids))
                       (d (table-ref *steps* id #f)))
                  (if (and d (story:eligible id d))
                      (begin (story:play! id d) #t)
                      (loop (cdr ids))))))))
    ;; Invariants still run while a scene panel holds new beats.
    (when (= (modulo *tick* 30) 0)
      (story:invariants!))))

(add-tick-hook! story-tick!)

;; ---- prompt / snapshot / debug ----------------------------------------------

;; Fold notable facts into the LLM prompt so replies follow the story state.
;; Only keys with a display label are shown; seen.* / invalid.* stay internal.
(define (story:prompt-line)
  (let loop ((pairs (hash-table->alist *story-labels*)) (parts '()))
    (if (null? pairs)
        (if (null? parts) "" (string-append "剧情进展：" (string-join parts "、") "。"))
        (let* ((key (car pairs))
               (label (cdr pairs)))
          (loop (cdr pairs)
                (if (and (string? label) (story:fact key))
                    (cons label parts)
                    parts))))))

(define (story:fact-rows)
  (map (lambda (p)
         (list (if (symbol? (car p)) (symbol->string (car p)) (car p))
               (cdr p)))
       *facts*))

(define (game:story-facts)
  (story:fact-rows))

;; (facts place last) — mirrored into Game.snapshot for HUD and acceptance.
(define (game:story-status)
  (list (story:fact-rows) *story-place* *story-last*))

;; The shell enables story evaluation once the start menu is resolved (or once
;; an acceptance replay begins). Not part of world state, so a reload/read
;; keeps it as-is.
(define (game:story-start)
  (set! *story-started* #t)
  #t)

;; Godot reports the nearest named anchor whenever it changes. This is a
;; semantic name, not world geometry, so Scheme still never copies coordinates.
(define (game:story-place place)
  (set! *story-place* place)
  (set! *story-arrived* #t)
  place)

;; The presentation panel pauses beat evaluation while it owns the keyboard.
(define (game:story-pause paused)
  (set! *story-paused* (if paused #t #f))
  *story-paused*)

(define (game:debug-set-fact key value)
  (story:set-fact! (string->symbol key) value))

(define (reset-story!)
  (set! *facts* '())
  (set! *story-place* "")
  (set! *story-last* "")
  (set! *story-arrived* #t)
  (set! *story-paused* #f))

;; ---- save slots -------------------------------------------------------------
(register-save-slot! 'story-facts (lambda () *facts*)
  (lambda (v) (set! *facts* v)) '())
(register-save-slot! 'story-place (lambda () *story-place*)
  (lambda (v) (set! *story-place* v)) "")
(register-save-slot! 'story-last (lambda () *story-last*)
  (lambda (v) (set! *story-last* v)) "")
