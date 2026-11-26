;; npcs.scm — lookups over the roster data in data/people.scm.
;;
;; The data itself (names, personas, schedules) is not here: this
;; file only answers "who is this npc" and "where should they be" questions.
;; Conversation flow lives in talk.scm; moving the body is Godot's job.

(require "game.util")
(require "game.data.people")
(require "game.data.maps")

;; Shared empty table returned when an npc has no canned lines, so callers can
;; table-ref it unconditionally.
(define *no-lines* (table))

;; npc ids are symbols here; the bridge converts strings once on entry.
(define (npc-entry npc)
  (table-ref *people* npc))

;; Topic -> canned line table for one npc; empty table for an unknown id.
(define (npc-fallback npc)
  (let ((p (npc-entry npc)))
    (if p (table-ref p 'lines *no-lines*) *no-lines*)))

(define (npc-persona npc)
  (let ((p (npc-entry npc)))
    (if p (table-ref p 'persona "你是村里的一位 NPC。") "你是村里的一位 NPC。")))

(define (npc-display npc)
  (let ((p (npc-entry npc)))
    (if p (table-ref p 'display (symbol->string npc)) (symbol->string npc))))

(define (game:npc-ids) *npcs*)

;; ---- schedules ---------------------------------------------------------------
;; A schedule is a list of tables (from / to / at / activity). Windows are
;; [from, to) in clock hours; `to` not after `from` wraps past midnight, so one
;; entry covers "22 to 6".

(define (npc-schedule npc)
  (let ((p (npc-entry npc)))
    (if p (table-ref p 'schedule '()) '())))

(define (hour-in-window? hour from to)
  (if (<= from to)
      (and (>= hour from) (< hour to))
      (or (>= hour from) (< hour to))))

(define (schedule-at sched hour)
  (if (null? sched)
      #f
      (let ((e (car sched)))
        (if (hour-in-window? hour
                            (table-ref e 'from 0)
                            (table-ref e 'to 24))
            e
            (schedule-at (cdr sched) hour)))))

;; (anchor activity) for the clock hour, or (#f idle) when no window matches.
(define (npc-plan npc hour)
  (let ((e (schedule-at (npc-schedule npc) hour)))
    (if e
        (list (table-ref e 'at "") (table-ref e 'activity 'idle))
        (list #f 'idle))))

;; "village:smithy" -> "smithy"; a bare name passes through.
(define (anchor-name at)
  (let ((i (string-index at ":")))
    (if i (substring at (+ i 1) (string-length at)) at)))

(define (anchor-map at)
  (let ((i (string-index at ":")))
    (if i (substring at 0 i) "")))

(define (member-string? s xs)
  (cond ((null? xs) #f)
        ((string=? s (car xs)) #t)
        (else (member-string? s (cdr xs)))))

;; Every schedule anchor must be declared on the map it names. Returns
;; ((npc-id at) ...) for the ones that are not; empty means the data is sound.
;; Each `at` is "map:anchor"; look up that map's own anchor list — the village
;; check alone would silently accept typos on the smithy (or any future map).
(define (schedule-problems)
  (let loop ((ids *npcs*) (acc '()))
    (if (null? ids)
        (reverse acc)
        (let ((npc (car ids)))
          (let loop2 ((s (npc-schedule npc)) (acc acc))
            (if (null? s)
                (loop (cdr ids) acc)
                (let* ((at (table-ref (car s) 'at ""))
                       (anchors (map-anchors (string->symbol (anchor-map at))))
                       (ok (and (not (null? anchors))
                                (member-string? (anchor-name at) anchors))))
                  (loop2 (cdr s)
                         (if ok acc
                             (cons (list (symbol->string npc) at) acc))))))))))

(define (report-schedule-problems)
  (if (null? (schedule-problems))
      '()
      (begin
        (display "[schedule] unknown anchor ")
        (display (cadr (car (schedule-problems))))
        (display " in ")
        (display (car (car (schedule-problems))))
        (newline)
        (report-schedule-problems))))

;; Data check runs on load: a typo in a schedule anchor shows up in the console
;; instead of silently parking an NPC.
(report-schedule-problems)

(define (game:debug-schedule) (schedule-problems))
