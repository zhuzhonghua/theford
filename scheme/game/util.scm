;; util.scm — small string/list helpers shared by the game modules.
;;
;; Loaded first by main.scm; other modules also (require "game.util") so they
;; can be read on their own.

;; ---- association lists ------------------------------------------------------

;; (alist-get alist key) — value for key, or #f. Thin wrapper over native
;; assoc; keeps call sites from spelling out (let ((hit (assoc key alist))) ...).
(define (alist-get alist key)
  (let ((hit (assoc key alist)))
    (if hit (cdr hit) #f)))

(define (alist-put alist key val)
  (cond ((null? alist) (list (cons key val)))
        ((equal? (caar alist) key) (cons (cons key val) (cdr alist)))
        (else (cons (car alist) (alist-put (cdr alist) key val)))))

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

;; ---- lists ------------------------------------------------------------------

(define (take-n l k)
  (cond ((or (<= k 0) (null? l)) '())
        (else (cons (car l) (take-n (cdr l) (- k 1))))))
