;; util.scm — small string/list helpers shared by the game modules.
;;
;; Loaded first by main.scm; other modules also (require "game.util") so they
;; can be read on their own.

;; ---- association lists ------------------------------------------------------

;; (alist-get alist key) — value for key, or #f. Thin wrapper over native
;; assoc; keeps call sites from spelling out (let ((hit (assoc key alist))) ...).
(define (alist-get alist key)
  (if (or (not alist) (null? alist))
      #f
      (let ((hit (assoc key alist)))
        (if hit (cdr hit) #f))))

(define (alist-put alist key val)
  (cond ((null? alist) (list (cons key val)))
        ((equal? (caar alist) key) (cons (cons key val) (cdr alist)))
        (else (cons (car alist) (alist-put (cdr alist) key val)))))

;; ---- tables -----------------------------------------------------------------
;;
;; Data DSL: `table` builds nested hash tables.
;;
;;   (table
;;     (smith                                ; a row: key + (field = value) pairs
;;       (display = "Old Wang")
;;       (lines = (table (greet = "Hey."))))  ; values may nest another table
;;     (greet = "a greeting"))                ; bare field = value entries
;;
;; Keys and field names are symbols and get quoted automatically; the value
;; after `=` is an ordinary expression.

(define-syntax table
  (syntax-rules (=)
    ((_) (make-hash-table))
    ;; a row: key followed by one or more (field = value) pairs
    ((_ (key (f = v) more ...) rest ...)
     (let ((h (table rest ...)))
       (hash-table-set! h 'key (table (f = v) more ...))
       h))
    ;; a scalar entry: field = value
    ((_ (f = v) rest ...)
     (let ((h (table rest ...)))
       (hash-table-set! h 'f v)
       h))))

;; (table-ref h key [default]) — value for key, or `default` (#f when omitted)
;; if the key is absent. A stored #f counts as present.
(define (table-ref h key . default)
  (if (hash-table-exists? h key)
      (hash-table-ref h key)
      (if (null? default) #f (car default))))

;; ---- save-slot registry -----------------------------------------------------
;; Each state module declares its own (key getter setter default [decoder]) at
;; load time; save.scm only walks this list. A new runtime state no longer
;; needs edits in save.scm's write list + load sequence.
(define *save-slots* '())

(define (register-save-slot! key getter setter default . decoder)
  (set! *save-slots*
        (append *save-slots*
                (list (list key getter setter default
                            (if (null? decoder) #f (car decoder)))))))

;; ---- strings ----------------------------------------------------------------

(define (string-index haystack needle)
  (let ((lh (string-length haystack))
        (ln (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i ln) lh) #f)
            ((string=? (substring haystack i (+ i ln)) needle) i)
            (else (loop (+ i 1)))))))

(define (string-index-from haystack needle from)
  (let ((lh (string-length haystack))
        (ln (string-length needle)))
    (let loop ((i from))
      (cond ((> (+ i ln) lh) #f)
            ((string=? (substring haystack i (+ i ln)) needle) i)
            (else (loop (+ i 1)))))))

(define (whitespace? c)
  (or (char=? c #\space)
      (char=? c #\newline)
      (char=? c #\tab)
      (char=? c #\return)))

(define (string-trim s)
  (let ((n (string-length s)))
    (let ((start (let loop ((i 0))
                   (cond ((= i n) n)
                         ((whitespace? (string-ref s i)) (loop (+ i 1)))
                         (else i))))
          (end (let loop ((i (- n 1)))
                 (cond ((< i 0) 0)
                       ((whitespace? (string-ref s i)) (loop (- i 1)))
                       (else (+ i 1))))))
      (if (>= start end) "" (substring s start end)))))

(define (string-replace-all s old new)
  (let ((ln (string-length old)))
    (if (= ln 0)
        s
        (let loop ((start 0) (acc ""))
          (let ((idx (string-index-from s old start)))
            (if (not idx)
                (string-append acc (substring s start (string-length s)))
                (loop (+ idx ln)
                      (string-append acc (substring s start idx) new))))))))

;; (string-fill template subs) — replace each {placeholder} in template, where
;; subs is an alist of ("{name}" . value). One pass per entry, in order.
(define (string-fill template subs)
  (if (null? subs)
      template
      (string-fill (string-replace-all template (caar subs) (cdar subs))
                   (cdr subs))))

;; (string-join parts sep) — concatenate a list of strings with a separator.
(define (string-join parts sep)
  (cond ((null? parts) "")
        ((null? (cdr parts)) (car parts))
        (else (string-append (car parts) sep (string-join (cdr parts) sep)))))

;; ---- lists ------------------------------------------------------------------

(define (take-n l k)
  (cond ((or (<= k 0) (null? l)) '())
        (else (cons (car l) (take-n (cdr l) (- k 1))))))

;; ---- small helpers dummyscheme does not provide -----------------------------
;; init.scm has every? but no any?, and no filter/sort.

(define (any? pred lst)
  (and (pair? lst)
       (or (pred (car lst))
           (any? pred (cdr lst)))))


;; Condition aggregation shared by rules.scm and story.scm: all/any of a
;; predicate over a list, short-circuiting. Keeps new condition keys from
;; needing their own loop.
(define (all-conds pred xs)
  (cond ((null? xs) #t)
        ((pred (car xs)) (all-conds pred (cdr xs)))
        (else #f)))

(define (any-conds pred xs)
  (and (pair? xs)
       (or (pred (car xs))
           (any-conds pred (cdr xs)))))

(define (string-prefix? prefix str)
  (let ((lp (string-length prefix))
        (ls (string-length str)))
    (and (<= lp ls)
         (string=? (substring str 0 lp) prefix))))

;; Remove every pair whose key matches; cmp is eq?, eqv? or equal?.
(define (alist-delete key alist cmp)
  (cond ((null? alist) '())
        ((cmp (caar alist) key) (alist-delete key (cdr alist) cmp))
        (else (cons (car alist) (alist-delete key (cdr alist) cmp)))))
