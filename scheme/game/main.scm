;; main.scm — The Ford (渡口) game logic.
;; Layer rule (plan_oss_edu_game.md section 3.1):
;;   Godot is presentation only. State changes live in Scheme:
;;   deterministic, serializable, replayable.
;;   The LLM turns topics into NPC lines. It proposes; Scheme decides.
;;
;; API used by scripts/game_bridge.gd:
;;   game:set-model-path path
;;   game:boot                 -> #t/#f (load local model, degrade gracefully)
;;   game:npc-ids              -> (smith apothecary innkeeper)
;;   game:topics npc-id        -> ((topic-key menu-label) ...) state-dependent
;;   game:greet npc-id         -> (opening-line quest-text carried-count)
;;   game:take-ore             -> carried count after picking up one ore
;;   game:talk npc-id topic    -> (reply quest-text carried-count)
;;   game:status               -> (quest-text carried-count)
;;
;; Playable without a model: when *use-llm* is #f every NPC falls back to
;; the canned reply table, and the quest still completes end to end.

;; The map is generated in its own file so main.scm stays about behaviour.
(require "game.map")

;; ---- helpers ---------------------------------------------------------------

(define (alist-get alist key)
  (cond ((null? alist) #f)
        ((equal? (caar alist) key) (cdar alist))
        (else (alist-get (cdr alist) key))))

(define (alist-put alist key val)
  (cond ((null? alist) (list (cons key val)))
        ((equal? (caar alist) key) (cons (cons key val) (cdr alist)))
        (else (cons (car alist) (alist-put (cdr alist) key val)))))

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

(define (string-prefix? s prefix)
  (let ((ls (string-length s))
        (lp (string-length prefix)))
    (and (>= ls lp)
         (string=? (substring s 0 lp) prefix))))

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

(define (take-n l k)
  (cond ((or (<= k 0) (null? l)) '())
        (else (cons (car l) (take-n (cdr l) (- k 1))))))

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

;; ---- model / llm infra (optional; degrade to canned lines) ------------------

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

;; ---- deterministic game state ------------------------------------------------

;; The smith's quest: not-offered -> accepted -> completed.
;; Ore picked up on the map increments *carried*; handing it over at the
;; smith's moves it to *delivered*. Only these setters below may change state.
(define *quest-state* 'not-offered)
(define *carried* 0)
(define *delivered* 0)

(define *histories* '())   ; ((npc-id . ((speaker . text) ...)) ...) newest first

(define (hist-add npc speaker text)
  (let ((old (or (alist-get *histories* npc) '())))
    (let ((next (cons (cons speaker text) old)))
      (set! *histories*
        (alist-put *histories* npc
          (if (> (length next) 12)
              (reverse (take-n (reverse next) 12))
              next))))))

(define (hist-recent npc n)
  (let* ((h (or (alist-get *histories* npc) '()))
         (recent (reverse (take-n h n))))
    (cond ((null? recent) "")
          (else (apply string-append
                        (map (lambda (p) (string-append (car p) ": " (cdr p) ". "))
                             recent))))))

;; ---- NPC roster ---------------------------------------------------------------

(define *npcs* '(smith apothecary innkeeper))

(define *fallback-smith*
  (list (cons 'greet "老王：来了？坐。炉子上的火不等人。")
        (cons 'village "老王：这村子叫渡口村。北岸的货都得从这儿过河。")
        (cons 'work "老王：给守卫打剑的活儿还没完，就缺铁矿石。")
        (cons 'quest "老王：正发愁呢。三块铁矿石，你给我找来，剑打好了少不了你。河边滩上冲下来的石头里有时候有那种好料。")
        (cons 'give "老王：好！我收下了。")))

(define *fallback-apothecary*
  (list (cons 'greet "陈婆：哟，是过路的孩子吧。脸色不太好，晒的？")
        (cons 'village "陈婆：喝河里的水要煮开。北岸的雾大，别贪走夜路。")
        (cons 'work "陈婆：我晒的草药下个集就齐了。")))

(define *fallback-innkeeper*
  (list (cons 'greet "张掌柜：客官住店？前头还有空房。")
        (cons 'village "张掌柜：渡口村，面小事多。规矩就一条：别惹老王。")
        (cons 'work "张掌柜：他那把剑还没打完呢。你也去帮帮忙吧。")))

(define (npc-fallback npc)
  (cond ((equal? npc "smith") *fallback-smith*)
        ((equal? npc "apothecary") *fallback-apothecary*)
        ((equal? npc "innkeeper") *fallback-innkeeper*)
        (else '())))

(define *personas*
  (list
    (cons "smith"
      "你正在扮演老王，渡口村东头的铁匠。老王性格豪爽、说话直来直去，常用『哼』『嘿』『得嘞』这类口头语。他正打算给村里的守卫打一把剑，但手头缺铁矿石，正为此发愁。")
    (cons "apothecary"
      "你正在扮演陈婆，渡口村的药师。陈婆细心、说话慢条斯理，喜欢叮咛人煮水喝、注意保暖。她晒草药为生，知道村里不少事。")
    (cons "innkeeper"
      "你正在扮演张掌柜，渡口村旅店的老板。张掌柜殷勤健谈，爱打听消息，见人先递一句招呼，嘴甜但不油滑。")))

(define *npc-display*
  (list (cons "smith" "老王")
        (cons "apothecary" "陈婆")
        (cons "innkeeper" "张掌柜")))

(define *sys-instruction*
  "你就是这个 NPC。只输出对玩家说的一句台词，不要加引号，不要加名字前缀，只用简短的日常中文，不要思考，不要替玩家说话。")

(define *topic-utterances*
  (list (cons 'greet "我路过村子，跟你打个招呼吧。")
        (cons 'village "给我讲讲渡口村的事吧。")
        (cons 'work "你最近手头的活计还顺利么？")))

(define *qt-text-not-offered* "任务：未接（找铁匠老王聊聊）")
(define *qt-text-accepted*    "任务：给老王找 3 块铁矿石（河边有矿点）")

(define (quest-text)
  (cond ((eq? *quest-state* 'not-offered) *qt-text-not-offered*)
        ((eq? *quest-state* 'accepted)
         (string-append "任务：给老王找铁矿石（已交 "
           (number->string *delivered*) " / 3，背上还有 "
           (number->string *carried*) " 块）"))
        (else "任务：完成！老王送了你一把铁剑。")))

;; ---- topic menu per NPC, depending on quest state -----------------------------

(define (game:topics npc)
  (cond ((equal? npc "smith")
         (append
           (list (cons 'greet "打个招呼")
                 (cons 'village "聊聊村子")
                 (cons 'work "问问活计"))
           (cond ((eq? *quest-state* 'not-offered)
                  (list (cons 'quest "接任务")))
                 ((eq? *quest-state* 'accepted)
                  (if (> *carried* 0)
                      (list (cons 'give (string-append "交矿石（背上 " (number->string *carried*) " 块）")))
                      (list (cons 'quest "聊聊进度"))))
                 (else '()))))
        (else
          (list (cons 'greet "打个招呼")
                (cons 'village "聊聊村子")
                (cons 'work "问问活计")))))

;; The bridge passes topics back as symbols; strings also tolerated.
(define (topic-key t)
  (cond ((symbol? t) t)
        ((string? t) (string->symbol t))
        (else 'greet)))

;; ---- greetings (canned; cheap, no LLM) -----------------------------------------

(define (game:greet npc)
  (let* ((kb (topic-key 'greet))
         (line (cond ((equal? npc "smith")
                      (cond ((eq? *quest-state* 'not-offered)
                             "老王：来了？坐。炉火不等人，有什么话快说。")
                            ((eq? *quest-state* 'accepted)
                             "老王：矿石找着了没？河边滩上冲下来的石头里看好料。")
                            (else "老王：哈哈，成事之人。到屋里坐，我去给你拿剑。")))
                      (else
                       (let ((fb (alist-get (npc-fallback npc) 'greet)))
                         (or fb "……"))))))
    (list line (quest-text) *carried*)))

;; ---- talk pipeline -------------------------------------------------------------

;; intent application: the ONLY place quest state changes.
;; returns (status . reason); status in (accepted rejected ignored)
(define (apply-intent intent)
  (cond ((eq? intent 'accept)
         (cond ((eq? *quest-state* 'not-offered)
                (begin (set! *quest-state* 'accepted)
                       (cons 'accepted "玩家接受了任务")))
               ((eq? *quest-state* 'accepted) (cons 'ignored "任务已经接过"))
               ((eq? *quest-state* 'completed) (cons 'rejected "任务早已完成"))
               (else (cons 'ignored ""))))
        ((eq? intent 'give)
         (cond ((eq? *quest-state* 'accepted)
                (cond ((<= *carried* 0) (cons 'rejected "玩家背上没有矿石"))
                      (else
                        (let ((n (min *carried* (- 3 *delivered*))))
                          (set! *carried* (- *carried* n))
                          (set! *delivered* (+ *delivered* n))
                          (if (>= *delivered* 3)
                              (begin
                                (set! *quest-state* 'completed)
                                (cons 'accepted (string-append "收下第 3 块矿石，任务完成，赠玩家一把铁剑")))
                              (cons 'accepted (string-append "收下 " (number->string n) " 块矿石（"
                                        (number->string *delivered*) " / 3）")))))))
               ((eq? *quest-state* 'not-offered) (cons 'rejected "任务还没接，不能收矿石"))
               ((eq? *quest-state* 'completed)   (cons 'rejected "任务已完成"))
               (else (cons 'ignored ""))))
        (else (cons 'ignored "闲聊，不动状态"))))

(define (verdict-hint status)
  (cond ((eq? status 'accepted) "老王的请求得到了满足，简短回应，语气高兴。")
        ((eq? status 'rejected) "老王必须拒绝，例如：不行，你还没接这活儿呢。")
        (else "只是闲聊，老王正常回应即可。")))

(define (build-prompt npc player-text status)
  (let ((persona (or (alist-get *personas* npc) "你是村里的一位 NPC。")))
    (string-append
      "<|im_start|>system\n"
      persona *sys-instruction* "<|im_end|>\n"
      "<|im_start|>user\n"
      "当前任务状态：" (quest-text) "\n"
      "玩家背包：铁矿石 x" (number->string *carried*) "\n"
      "刚刚的判定：Scheme 结果=" (symbol->string (car status))
      "，原因=" (cdr status) "\n"
      (verdict-hint (car status)) "\n\n"
      "对话记录：\n"
      (hist-recent npc 6) "\n"
      "玩家：" player-text "<|im_end|>\n"
      ;; Qwen3 thinking-off prefill (same trick as test/npc-demo.scm):
      "<|im_start|>assistant\n<think>\n\n</think>")))

(define (fallback-line npc topic)
  (or (alist-get (npc-fallback npc) topic)
      (cond ((eq? topic 'quest) "老王：正忙，过会儿再说。")
            ((eq? topic 'give)  "老王：先把矿石找来再说。")
            (else "……"))))

;; ---- learned lines (cache) ------------------------------------------------------
;; Same idea as openworld's learned.ts: an LLM-generated line is proposed
;; once, then it belongs to the village. For the exact same
;; (npc, topic, quest-state) the replayed answer is deterministic — the
;; second ask never hits the model. Returns a (line . learned?) pair.
(define *learned* '())

(define (learn-key npc t)
  (string-append npc "/" (symbol->string t) "/"
    (cond ((eq? *quest-state* 'completed) "2")
          ((eq? *quest-state* 'accepted)  "1")
          (else "0"))))

(define (learn-get key)
  (let ((hit (alist-get *learned* key)))
    (and (string? hit) (not (string=? hit "")) hit)))

(define (learn-put! key line)
  (set! *learned* (alist-put *learned* key line)))

(define (llm-line npc t prompt)
  (let ((key (learn-key npc t)))
    (let ((hit (learn-get key)))
      (cond (hit (cons hit #t))
            (else
             (let ((l (generate-line prompt 120)))
               (cond ((string=? l "") (cons (fallback-line npc t) #f))
                     (else (learn-put! key l) (cons l #f)))))))))

(define (plain-line npc t)
  (cons (fallback-line npc t) #f))

;; one conversational turn: canned path and llm path share the same plumbing
;; Order matters: Scheme judges FIRST (state change is deterministic), then
;; the LLM narrates — it may never see a state it did not produce.
(define (game:talk npc topic)
  (let* ((t (topic-key topic))
         (quest-topic (and (equal? npc "smith") (or (eq? t 'quest) (eq? t 'give))))
         (intent (cond ((and (eq? t 'quest) (eq? *quest-state* 'not-offered)) 'accept)
                       ((eq? t 'give) 'give)
                       (else 'chat)))
         (verdict (apply-intent intent))
         (player-text
           (cond ((eq? intent 'accept) "我想接下你的任务。")
                 ((and (eq? intent 'give) (eq? (car verdict) 'accepted))
                  "给你，矿石都在这儿。")
                 ((or (eq? t 'quest) (eq? t 'give)) (or (alist-get *topic-utterances* 'work) "……"))
                 (else (or (alist-get *topic-utterances* t) "……"))))
         ;; Path 2: quest happenings stay canned (deterministic by design);
         ;; Path 3: village / work / plain chat goes through the LLM,
         ;; then through the learned cache.
         (reply
           (cond ((not *use-llm*) (plain-line npc t))
                 ((and quest-topic (not (eq? (car verdict) 'ignored)))
                  (cons (canned-quest-line npc verdict) #f))
                 (quest-topic (plain-line npc t))
                 (else (llm-line npc t (build-prompt npc player-text verdict))))))
    (hist-add npc "玩家" player-text)
    (hist-add npc (or (alist-get *npc-display* npc) npc) (car reply))
    ;; (reply quest-text carried learned?) — learned? drives the "📖 记住了"
    ;; marker in the dialog panel.
    (list (car reply) (quest-text) *carried* (cdr reply))))

;; The LLM is told what happened (verdict), but the canonical line for quest
;; milestones is scripted — the same reason cutscenes are scripted.
(define (canned-quest-line npc verdict)
  (cond ((eq? (car verdict) 'accepted)
         (cond ((eq? *quest-state* 'accepted)
                "老王：好嘞！三块铁矿石，河边滩上冲下来的石头里看好料。找着了拿来我这儿。")
               ((eq? *quest-state* 'completed)
                "老王：得了！矿石齐了，剑也成了。给你——往后就是渡口村的人了。")))
        ((eq? (car verdict) 'rejected) "老王：这可不行，先把矿石找来。")
        (else (fallback-line npc 'work))))

;; ---- pickups and status ----------------------------------------------------------

(define (game:take-ore)
  (set! *carried* (+ *carried* 1))
  *carried*)

(define (game:status)
  (list (quest-text) *carried*))

(define (game:npc-ids) *npcs*)
