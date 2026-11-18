;; time.scm — clock and weather. Data-driven; semantics follow the reference
;; calendar (10 ticks = 1 game minute, day 1 at startHour, days flip at
;; midnight) and the reference seeded hash/PRNG.
;;
;; One real second = one game minute (Godot calls game:tick every 0.1s), so a
;; day is 24 real minutes.
;;
;; Weather: world data may fix spans (weatherPlan); otherwise day 1 is always
;; sun and later days draw from a stateless hash of (seed, day) — the same
;; seed replays the same weather, no rolling history needed.
;;
;; Public surface:
;;   *tick*                 absolute tick counter
;;   clock-at tick          (day hour minute), integers
;;   current-weather        weather symbol for now
;;   time-status            (day hour minute weather)
;;   next-random            mulberry32 PRNG in [0,1), seeded from world seed
;;   reset-time!            tick 0 + PRNG reseed (used by game:reload)
;;   game:tick              advance one tick, returns game:status

(require "game.util")
(require "game.data.world")

(define ticks-per-minute 10)
(define ticks-per-hour 600)
(define ticks-per-day 14400)

(define *tick* 0)

(define (world-field key default)
  (table-ref *world* key default))

(define (start-hour) (world-field 'startHour 8))
(define (world-seed) (world-field 'seed 7))

;; ---- 32-bit helpers ----------------------------------------------------------
;; dummyscheme integers are 64-bit; the reference hash/PRNG are 32-bit, so mask
;; after every step. Right shift of an already-u32 value is logical either way.

(define (u32 x) (modulo x 4294967296))
(define (imul a b) (u32 (* a b)))
(define (ushr x n) (bitwise-arithmetic-shift x (- n)))

;; murmur3 finalizer, same constants as the reference hash(); result in [0,1).
(define (hash01 n)
  (let ((x (u32 (bitwise-xor (u32 n) 2654435769))))          ; 0x9e3779b9
    (set! x (imul (bitwise-xor x (ushr x 16)) 2246822507))  ; 0x85ebca6b
    (set! x (imul (bitwise-xor x (ushr x 13)) 3266489909))  ; 0xc2b2ae35
    (/ (u32 (bitwise-xor x (ushr x 16))) 4294967296.0)))

;; mulberry32: the reference general-purpose PRNG. State lives here so runs
;; replay from the world seed.
(define *rng-state* (world-seed))

(define (next-random)
  (set! *rng-state* (u32 (+ *rng-state* 1831565813)))         ; 0x6d2b79f5
  (let ((t *rng-state*))
    (set! t (imul (bitwise-xor t (ushr t 15)) (bitwise-ior t 1)))
    (set! t (u32 (bitwise-xor t
                  (+ t (imul (bitwise-xor t (ushr t 7)) (bitwise-ior t 61))))))
    (/ (u32 (bitwise-xor t (ushr t 14))) 4294967296.0)))

;; ---- clock -------------------------------------------------------------------

;; (day hour minute), all integers; day starts at 1.
(define (clock-at tick)
  (let* ((total (+ (* (start-hour) ticks-per-hour) tick))
         (day-index (quotient total ticks-per-day))
         (rem (- total (* day-index ticks-per-day))))
    (list (+ day-index 1)
          (quotient rem ticks-per-hour)
          (quotient (modulo rem ticks-per-hour) ticks-per-minute))))

;; ---- weather -----------------------------------------------------------------

;; GM override: when set, current-weather returns it regardless of the seed.
;; reset-time! clears it so a hot reload goes back to the authored weather.
(define *weather-override* #f)

;; First matching fixed-weather span, or #f. A span is a table with day and
;; weather, optional from/to hours ([from, to), default whole day).
(define (weather-span day hour)
  (let loop ((spans (world-field 'weatherPlan '())))
    (if (null? spans)
        #f
        (let ((s (car spans)))
          (if (and (= (table-ref s 'day 0) day)
                   (>= hour (table-ref s 'from 0))
                   (< hour (table-ref s 'to 24)))
              (table-ref s 'weather 'sun)
              (loop (cdr spans)))))))

(define (weather-at day hour)
  (let ((span (weather-span day hour)))
    (cond (span span)
          ((= day 1) 'sun)
          (else
            (let ((r (hash01 (+ (* (world-seed) 7919) (* day 104729)))))
              (cond ((< r 0.5) 'sun)
                    ((< r 0.75) 'cloud)
                    ((< r 0.9) 'rain)
                    ((< r 0.95) 'storm)
                    (else 'fog)))))))

(define (current-weather)
  (if *weather-override*
      *weather-override*
      (let ((c (clock-at *tick*)))
        (weather-at (car c) (cadr c)))))

(define (time-status)
  (let ((c (clock-at *tick*)))
    (list (car c) (cadr c) (caddr c) (current-weather))))

(define (reset-time!)
  (set! *tick* 0)
  (set! *rng-state* (world-seed))
  (set! *weather-override* #f))

(define (game:tick)
  (set! *tick* (+ *tick* 1))
  (game:status))

