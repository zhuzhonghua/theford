;; llm.scm — optional local-model plumbing (scmllama) and output cleanup.
;;
;; The game is fully playable without a model: *use-llm* stays #f and every
;; NPC falls back to canned lines. Everything here degrades gracefully through
;; pcall, so a missing/broken model never takes the game down.

(require "game.util")

;; ---- raw output cleanup -----------------------------------------------------

;; Drop Qwen3 think blocks and special tokens from raw generation output.
(define *think-open* "<think>")
(define *think-close* "</think>")

(define (strip-think text)
  (let ((start (string-index text *think-open*)))
    (cond ((not start) text)
          (else
            (let ((end (string-index-from text *think-close* start)))
              (cond ((not end) (substring text 0 start))
                    (else (strip-think
                            (string-append (substring text 0 start)
                                           (substring text end (string-length text)))))))))))

(define (strip-special text)
  (let ((clean (strip-think text)))
    (let ((start (string-index clean "<|im_start|>")))
      (if (not start)
          clean
          (let ((eos (string-index clean "<|im_end|>")))
            (if eos (substring clean 0 eos) clean))))))

;; ---- model / llm infra ------------------------------------------------------

(define *model-path* #f)
(define *use-llm* #f)
(define *model* #f)
(define *ctx* #f)
(define *smpl* #f)

(define (game:set-model-path path)
  (set! *model-path* path))

(define (boot-llm)
  (let ((r (pcall (lambda ()
            (llm-quiet! #t)
            (set! *model* (llm-model-load *model-path*))
            (set! *ctx* (llm-context-new *model* (list (cons 'n-ctx 1024))))
            (set! *smpl* (llm-sampler-new *model*
                          (list (cons 'temp 0.85)
                                (cons 'top-k 40)
                                (cons 'top-p 0.92)
                                (cons 'penalty-last-n 64)
                                (cons 'penalty-repeat 1.15)
                                (cons 'penalty-freq 0.4)
                                (cons 'penalty-present 0.2))))))))
    (if (eq? (car r) #f) #f #t)))

(define (game:boot)
  (if (string? *model-path*)
      (begin
        (set! *use-llm* (boot-llm))
        *use-llm*)
      #f))

(define (generate-line prompt tokens)
  ;; Protected: on any error return "" so the caller uses the canned line.
  (let ((r (pcall (lambda ()
            (string-trim
              (strip-special
                (llm-generate
                  *ctx* *smpl* prompt
                  (stream-callback)
                  (list (cons 'max-tokens tokens)
                        (cons 'parse-special #t)))))))))
    (if (eq? (car r) #f) "" (cdr r))))

;; Per-token streaming: forward human-visible pieces to the host (Godot
;; drains them live), while llm-generate keeps collecting the full text.
;; Qwen3 think-blocks and special-token markers are muted on the way out.
;; Requires the host to register `llm-stream-push`; if absent, the error is
;; swallowed by generate-line's pcall and the caller falls back to canned.
(define (stream-callback)
  (let ((sup #f))
    (lambda (piece)
      (cond ((string-index piece "etak") (set! sup #t))
            (sup (let ((e (string-index piece "=>")))
                   (if e (set! sup #f))))
            ((string-index piece "<|"))
            (else (llm-stream-push piece)))
      #t)))
