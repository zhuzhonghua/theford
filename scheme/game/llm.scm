;; llm.scm — optional local-model plumbing (scmllama) and output cleanup.
;;
;; The game is fully playable without a model: *use-llm* stays #f and every
;; NPC falls back to canned lines. No pcall anywhere on purpose: the VM call
;; boundary already catches everything (scm_apply reports an error string to
;; Godot), and degradation happens there — a failed boot means canned lines,
;; a failed turn means the silent-turn message. Internal helpers are written
;; plainly.

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
;; The host's token sink (a native fn registered by the extension). Bound at
;; boot so a host without it fails there, not on the first generated token.
(define *stream-sink* #f)

(define (game:set-model-path path)
  (set! *model-path* path))

(define (boot-llm)
  ;; Host contract first: the extension registers `llm-stream-push`; the bare
  ;; CLI vm does not, so this reference raises "undefined global var" here at
  ;; boot instead of mid-generation. That forbids model use without the
  ;; extension while canned-line play still works everywhere.
  (set! *stream-sink* llm-stream-push)
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
  (set! *use-llm* #t)
  )

(define (game:boot)
  (if (string? *model-path*)
      (begin
        (boot-llm)
        *use-llm*)
      #f))

;; (model-desc use-llm? llama.cpp-version) — read by the bridge for the HUD.
(define (game:engine-info)
  (list (if (string? *model-desc*) *model-desc* "")
        (if *use-llm* #t #f)
        (if (string? *llama-version*) *llama-version* "")))

(define (generate-line prompt tokens)
  ;; Any error aborts the whole turn; the call boundary degrades it to the
  ;; silent-turn line. talk.scm only touches history/cache after this
  ;; returns, so a mid-generation failure leaves no half-updated state.
  ;; Each turn rebuilds the prompt from history, so start from a clean KV
  ;; cache: otherwise cached tokens accumulate across turns and eventually
  ;; overflow n-ctx. Perf counters are per-turn too.
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
    text))

;; Snapshot the perf table into a plain (prefill decode) pair. Done once,
;; right where the context is known good, so the HUD path is a plain read.
(define (snapshot-perf)
  (let ((t (llm-perf *ctx*)))
    (set! *last-perf* (list (hash-table-ref t "prefill-tps")
                            (hash-table-ref t "decode-tps")))))

;; (prefill-tps decode-tps) of the latest LLM generation; zeros for canned
;; turns, so the HUD never shows a stale model speed next to a scripted line.
(define (game:last-perf)
  (if *last-perf* *last-perf* (list 0.0 0.0)))

;; Per-token streaming: forward human-visible pieces to the host (Godot
;; drains them live), while llm-generate keeps collecting the full text.
;; Qwen3 think-blocks and special-token markers are muted on the way out.
;; *stream-sink* is the host's registered push fn, bound in boot-llm.
(define (stream-callback)
  (let ((sup #f))
    (lambda (piece)
      (cond ((string-index piece "etak") (set! sup #t))
            (sup (let ((e (string-index piece "=>")))
                   (if e (set! sup #f))))
            ((string-index piece "<|"))
            (else (*stream-sink* piece)))
      #t)))
