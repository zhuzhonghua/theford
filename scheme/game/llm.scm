;; llm.scm — optional local-model plumbing (scmllama) and output cleanup.
;;
;; The game is fully playable without a model: *use-llm* stays #f and every
;; NPC falls back to canned lines. Only two places are wrapped in pcall, and
;; both are real boundaries: loading a file from disk, and generating. The VM
;; call boundary already catches everything (scm_apply reports an error string
;; to Godot), so pcall here is a UX policy — "a broken model still talks" —
;; not crash protection. Internal helpers are written plainly on purpose.

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
;; Shown in the mechanism HUD: which local model the village is speaking with.
(define *model-desc* "")
(define *llama-version* "")
;; llm-perf hash-table of the latest generation (prefill/decode t/s), or #f.
(define *last-perf* #f)

(define (game:set-model-path path)
  (set! *model-path* path))

(define (boot-llm)
  ;; pcall yields (ok . value); car is the flag, not the pair itself.
  (car (pcall (lambda ()
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
                             (cons 'penalty-present 0.2))))
         ;; Metadata is safe here: if model-load succeeded the handle is valid,
         ;; and llm-model-info/llm-version never throw on a valid handle.
         (set! *llama-version* (llm-version))
         (set! *model-desc*
               (hash-table-ref (llm-model-info *model*) "desc"))
         #t))))

(define (game:boot)
  (if (string? *model-path*)
      (begin
        (set! *use-llm* (boot-llm))
        *use-llm*)
      #f))

;; (model-desc use-llm? llama.cpp-version) — read by the bridge for the HUD.
(define (game:engine-info)
  (list (if (string? *model-desc*) *model-desc* "")
        (if *use-llm* #t #f)
        (if (string? *llama-version*) *llama-version* "")))

(define (generate-line prompt tokens)
  ;; Protected: on any error return "" so the caller uses the canned line.
  (let ((r (pcall (lambda ()
            ;; Each turn rebuilds the prompt from history, so start from a
            ;; clean KV cache: otherwise cached tokens accumulate across turns
            ;; and eventually overflow n-ctx. Perf counters are per-turn too.
            (llm-reset *ctx*)
            (llm-perf-reset *ctx*)
            (let ((text (string-trim
                          (strip-special
                            (llm-generate
                              *ctx* *smpl* prompt
                              (stream-callback)
                              (list (cons 'max-tokens tokens)
                                    (cons 'parse-special #t)))))))
              (snapshot-perf)
              text)))))
    (if (eq? (car r) #f) "" (cdr r))))

;; Snapshot the perf table into a plain (prefill decode) pair. Done once, right
;; where the context is known good, so the HUD path needs no guarded lookups.
;; A perf failure must not cost us the generated line, hence the inner pcall.
(define (snapshot-perf)
  (let ((r (pcall (lambda ()
            (let ((t (llm-perf *ctx*)))
              (list (hash-table-ref t "prefill-tps")
                    (hash-table-ref t "decode-tps")))))))
    (set! *last-perf* (if (eq? (car r) #f) #f (cdr r)))))

;; (prefill-tps decode-tps) of the latest LLM generation; zeros for canned
;; turns, so the HUD never shows a stale model speed next to a scripted line.
(define (game:last-perf)
  (if *last-perf* *last-perf* (list 0.0 0.0)))

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
