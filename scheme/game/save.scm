;; save.scm — saves as plain s-expression data.
;;
;; A save file is one nested list read straight by `(read port)` — no `define`,
;; no `table`, no executable forms. The `table` DSL stays where it belongs: in
;; data/*.scm. Here every runtime value is flattened to ordinary data:
;;
;;   ((version 1)
;;    (host (village (376 424) ...))
;;    (tick 3600)
;;    (bag ((item/tool/axe . 1) ...))
;;    (quests ((smith-ore (stage 20) (progress ((ore 3))) (histories ()))))
;;    ...)
;;
;; Godot owns pixel positions, so it supplies `host` when saving and reads it
;; back with game:peek-save before rebuilding the map.

(require "game.util")

(define SAVE_VERSION 1)

;; `write` escapes non-printable bytes as \-26, but this reader has no numeric
;; escapes and reads that back as "-26" — Chinese would be corrupted. Emit raw
;; UTF-8 inside quotes, escaping only the chars the reader special-cases.
(define (save:string s p)
  (display "\"" p)
  (let loop ((i 0))
    (if (< i (string-length s))
        (let ((c (string-ref s i)))
          (cond
            ((char=? c #\") (display "\\\"" p))
            ((char=? c #\\) (display "\\\\" p))
            ((char=? c #\newline) (display "\\n" p))
            (else (display c p)))
          (loop (+ i 1)))))
  (display "\"" p))

;; Any runtime value → plain s-expression data. Hash tables become lists of
;; (key value) pairs; dotted pairs keep their dot so alists round-trip exactly.
(define (save:plain v p)
  (let ((t (type v)))
    (cond
      ((equal? t 'hash-table)
       (display "(" p)
       (for-each (lambda (kv)
                   (display " (" p)
                   (write (car kv) p)
                   (display " " p)
                   (save:plain (cdr kv) p)
                   (display ")" p))
                 (hash-table->alist v))
       (display ")" p))
      ((equal? t 'pair)
       (display "(" p)
       (save:plain (car v) p)
       (let loop ((d (cdr v)))
         (cond ((equal? (type d) 'null) (display ")" p))
               ((equal? (type d) 'pair)
                (display " " p) (save:plain (car d) p) (loop (cdr d)))
               (else (display " . " p) (save:plain d p) (display ")" p)))))
      ((equal? t 'string) (save:string v p))
      (else (write v p)))))

(define (game:save path host)
  (let ((p (open-output-file path)))
    (display "(" p)
    (for-each
      (lambda (slot)
        (display "(" p)
        (display (car slot) p)
        (display " " p)
        (save:plain (cdr slot) p)
        (display ")\n" p))
      (list (cons 'version SAVE_VERSION)
            (cons 'host host)
            (cons 'tick *tick*)
            (cons 'rng *rng-state*)
            (cons 'weather *weather-override*)
            (cons 'map *current-map*)
            (cons 'bag *bag*)
            (cons 'equipped *equipped*)
            (cons 'xp *xp*)
            (cons 'completions *quest-completions*)
            (cons 'quests *quests-state*)
            (cons 'containers *containers*)
            (cons 'entities *entities*)
            (cons 'learned *learned*)))
    (display ")\n" p)
    (close-output-port p))
  #t)

(define (save:read path)
  (let ((p (open-input-file path))
        (d '()))
    (set! d (read p))
    (close-input-port p)
    d))

;; Sections are proper (key value) lists, so the value is (cadr entry).
;; A saved #f / () counts as absent and falls back to the default.
(define (save:get data key default)
  (let ((hit (assoc key data)))
    (if hit (cadr hit) default)))

;; Read `host` without applying any game state. A bad file makes `read` throw;
;; the host boundary catches that and hands GDScript an empty result.
(define (game:peek-save path)
  (let* ((d (save:read path))
         (h (save:get d 'host #f)))
    (if (and (= (save:get d 'version 0) SAVE_VERSION) h) h #f)))

;; Rebuild one quest state hash from ((stage n) (progress ((ore 3))) ...).
(define (save:quest-table rows)
  (let ((st (make-hash-table)))
    (for-each
      (lambda (kv)
        (let ((k (car kv))
              (v (cadr kv)))
          (hash-table-set! st k
            (if (equal? k 'progress)
                (let ((h (make-hash-table)))
                  (for-each (lambda (pv) (hash-table-set! h (car pv) (cadr pv))) v)
                  h)
                v))))
      rows)
    st))

(define (game:load path)
  (let ((d (save:read path)))
    (if (not (= (save:get d 'version 0) SAVE_VERSION))
        (list #f (game:status))
        (begin
          ;; A load starts from a clean boot, then overlays the saved values.
          (game:reload)
          (set! *tick* (save:get d 'tick 0))
          (set! *rng-state* (save:get d 'rng (world-seed)))
          (set! *weather-override* (save:get d 'weather #f))
          (set! *current-map* (save:get d 'map 'village))
          (set! *bag* (save:get d 'bag '()))
          (set! *equipped* (save:get d 'equipped #f))
          (set! *xp* (save:get d 'xp 0))
          (set! *quest-completions* (save:get d 'completions 0))
          (set! *quests-state*
                (map (lambda (row)
                       (cons (car row) (save:quest-table (cdr row))))
                     (save:get d 'quests '())))
          (set! *containers* (save:get d 'containers '()))
          (set! *entities* (save:get d 'entities '()))
          (set! *learned* (save:get d 'learned '()))
          (list #t (game:status))))))
