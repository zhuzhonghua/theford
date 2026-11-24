;; save.scm — saves written in the project's own `table` DSL.
;;
;; A save file looks just like a data file: nested (table (field = value) ...)
;; for records, quote / (list ...) for sequences — the same vocabulary people.scm
;; and maps.scm use. The writer is the inverse of the `table` macro: any hash
;; table found while walking runtime state becomes a `table` form, so quest
;; progress is never flattened by hand.
;;
;;   (define *save-data*
;;     (table
;;       (version = 1)
;;       (host = (list "village" (list 376 424) (list ...)))
;;       (bag = '((item/tool/axe . 1) (item/material/ore . 3)))
;;       (quests = (list (list 'smith-ore
;;                             (table (stage = 20)
;;                                    (progress = (table (ore = 3)))
;;                                    (histories = '())))))))
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

(define (save:has-table? v)
  (let ((t (type v)))
    (cond ((equal? t 'hash-table) #t)
          ((equal? t 'pair) (or (save:has-table? (car v))
                             (save:has-table? (cdr v))))
          (else #f))))

;; Quoted literal (no hash tables inside): write pairs with their real dotted
;; shape, like data/dialogue.scm does, so alists round-trip exactly.
(define (save:literal v p)
  (let ((t (type v)))
    (cond
      ((equal? t 'pair)
       (display "(" p)
       (save:literal (car v) p)
       (let loop ((d (cdr v)))
         (cond ((equal? (type d) 'null) (display ")" p))
               ((equal? (type d) 'pair)
                (display " " p) (save:literal (car d) p) (loop (cdr d)))
               (else (display " . " p) (save:literal d p) (display ")" p)))))
      ((equal? t 'string) (save:string v p))
      (else (write v p)))))

;; A pair that contains a hash table cannot be quoted (the table form would
;; never be evaluated). Emit a (list ...) expression instead; a dotted pair
;; becomes a two-element list, which the loader turns back into a pair.
(define (save:expr-pair v p)
  (display "(list" p)
  (let loop ((x v))
    (display " " p)
    (save:expr (car x) p)
    (let ((d (cdr x)))
      (cond ((equal? (type d) 'null) (display ")" p))
            ((equal? (type d) 'pair) (loop d))
            (else (display " " p) (save:expr d p) (display ")" p))))))

;; Any runtime value → source for an expression that rebuilds it.
(define (save:expr v p)
  (let ((t (type v)))
    (cond
      ((equal? t 'hash-table)
       (display "(table" p)
       (for-each (lambda (kv)
                   (display " (" p)
                   (write (car kv) p)      ; keys are symbols; table quotes them
                   (display " = " p)
                   (save:expr (cdr kv) p)
                   (display ")" p))
                 (hash-table->alist v))
       (display ")" p))
      ((equal? t 'pair)
       (if (save:has-table? v)
           (save:expr-pair v p)
           (begin (display "'" p) (save:literal v p))))
      ((equal? t 'symbol) (display "'" p) (write v p))
      ((equal? t 'string) (save:string v p))
      (else (write v p)))))

(define (game:save path host)
  (let ((p (open-output-file path)))
    (display "(define *save-data*\n  (table\n" p)
    (for-each
      (lambda (slot)
        (display "    (" p)
        (display (car slot) p)
        (display " = " p)
        (save:expr (cdr slot) p)
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
    (display "))\n" p)
    (close-output-port p))
  #t)

;; Read `host` without applying any game state. A bad file makes `load` throw;
;; the host boundary catches that and hands GDScript an empty result.
(define (game:peek-save path)
  (load path)
  (let ((d *save-data*))
    (if (and (= (table-ref d 'version 0) SAVE_VERSION)
             (table-ref d 'host #f))
        (table-ref d 'host)
        #f)))

(define (game:load path)
  (load path)
  (let ((d *save-data*))
    (if (not (= (table-ref d 'version 0) SAVE_VERSION))
        (list #f (game:status))
        (begin
          ;; A load starts from a clean boot, then overlays the saved values.
          (game:reload)
          (set! *tick* (table-ref d 'tick 0))
          (set! *rng-state* (table-ref d 'rng (world-seed)))
          (set! *weather-override* (table-ref d 'weather #f))
          (set! *current-map* (table-ref d 'map 'village))
          (set! *bag* (table-ref d 'bag '()))
          (set! *equipped* (table-ref d 'equipped #f))
          (set! *xp* (table-ref d 'xp 0))
          (set! *quest-completions* (table-ref d 'completions 0))
          ;; Quest rows are (id (stage/progress/histories table)) — the inner
          ;; tables came back from `table` forms, no manual rebuild needed.
          (set! *quests-state*
                (map (lambda (row) (cons (car row) (cadr row)))
                     (table-ref d 'quests '())))
          (set! *containers* (table-ref d 'containers '()))
          (set! *entities* (table-ref d 'entities '()))
          (set! *learned* (table-ref d 'learned '()))
          (list #t (game:status))))))
