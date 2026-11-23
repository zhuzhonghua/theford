;; gm.scm — optional debug module: deterministic GM commands + natural language.
;;
;; Everything a developer needs to exercise the village lives here, so a
;; release build can drop the tool in two steps:
;;   1. delete scripts/gm/ and scheme/game/gm.scm
;;   2. remove the (require "game.gm") line at the bottom of main.scm
;; main.gd loads the console by path and llm.scm only exposes *post-boot-hook*,
;; so neither needs another edit.
;;
;; The player types ordinary Chinese in the GM console; a small model maps it to
;; exactly one command. Generation is grammar-constrained, so the model can only
;; emit an existing command shape. This layer never decides game state: Godot
;; parses and runs the resulting command, and the Scheme game rules stay
;; authoritative.

(require "game.util")
(require "game.llm")
(require "game.time")
(require "game.npcs")
(require "game.data.maps")

;; ---- command samplers --------------------------------------------------------

(define *gm-smpl* #f)
(define *gm-free-smpl* #f)

;; GBNF grammar: generation can only produce an existing GM command. This is
;; what makes a 0.6B model usable as an intent parser — it cannot ramble or
;; invent a command name.
(define *gm-grammar*
  (string-append
    "root ::= space* cmd space*\n"
    "space ::= [ \\n\\t]\n"
    "cmd ::= time | advance | day | speed | weather | people | state | anchors | npc | tp | goto | talk | reload\n"
    "time ::= \"time \" hour \":\" minute\n"
    "advance ::= \"time +\" digits\n"
    "day ::= \"day \" digits\n"
    "speed ::= \"speed \" number\n"
    "weather ::= \"weather \" weather-name\n"
    "people ::= \"people\"\n"
    "state ::= \"state\"\n"
    "anchors ::= \"anchors\"\n"
    "npc ::= \"npc \" npc-id \" auto\" | \"npc \" npc-id \" \" anchor \" \" activity\n"
    "tp ::= \"tp \" npc-id\n"
    "goto ::= \"goto \" anchor\n"
    "talk ::= \"talk \" npc-id\n"
    "reload ::= \"reload\"\n"
    "number ::= digits | digits \".\" digits\n"
    "weather-name ::= \"sun\" | \"cloud\" | \"rain\" | \"storm\" | \"fog\" | \"auto\"\n"
    "npc-id ::= \"smith\" | \"apothecary\" | \"innkeeper\"\n"
    "anchor ::= \"smithy-door\" | \"herb-garden\" | \"inn\" | \"inn-yard\" | \"riverbank\" | \"village-square\" | \"smith-home\" | \"apothecary-home\" | \"innkeeper-home\"\n"
    "activity ::= \"smithing\" | \"herbs\" | \"innkeeping\" | \"lunch\" | \"drinking\" | \"strolling\" | \"sleep\" | \"idle\"\n"
    "hour ::= [01][0-9] | \"2\"[0-3]\n"
    "minute ::= [0-5][0-9]\n"
    "digits ::= [0-9]+"))

;; LLM silent generation: the token sink feeds the NPC dialogue box, so the GM
;; path must not stream, and it must not overwrite *last-perf* (the mechanism
;; HUD keeps showing the last dialogue turn).
(define (generate-command prompt tokens)
  (llm-reset *ctx*)
  (llm-sampler-reset *gm-smpl*)
  (string-trim
    (strip-special
      (llm-generate *ctx* *gm-smpl* prompt
        (lambda (piece) #t)
        (list (cons 'max-tokens tokens)
              (cons 'parse-special #t))))))

;; Same call without the grammar, for diagnosing prompt vs grammar problems.
(define (generate-command-free prompt tokens)
  (llm-reset *ctx*)
  (llm-sampler-reset *gm-free-smpl*)
  (string-trim
    (strip-special
      (llm-generate *ctx* *gm-free-smpl* prompt
        (lambda (piece) #t)
        (list (cons 'max-tokens tokens)
              (cons 'parse-special #t))))))

;; ---- prompt ------------------------------------------------------------------

(define *gm-prompt-template*
  "<|im_start|>system\n你是《渡口》的调试指令翻译器。把玩家的话翻译成一条 GM 指令。只输出指令本身，不要解释、不要引号、不要 markdown。\n可用指令（各占一行）：\ntime HH:MM 跳到今天该时刻，已过则明天\ntime +N 前进 N 游戏分钟\nday N 跳到第 N 天，时刻不变\nspeed N 时间倍速：0=暂停，1=正常，10=十倍\nweather W W 取 sun|cloud|rain|storm|fog|auto（auto 恢复自然天气）\npeople 查看 NPC 日程\nstate 查看整体状态\nanchors 查看全部锚点\nnpc <npc-id> <anchor> <activity> 命令该 NPC 走到某锚点做某事\nnpc <npc-id> auto 该 NPC 恢复日常日程\ntp <npc-id> 玩家传送到该 NPC 身边\ngoto <anchor> 玩家传送到某锚点\ntalk <npc-id> 玩家传送到该 NPC 身边并对话\nreload 热重载数据\n区别：说“让我/带我/我去找某人”用 tp 或 talk；说“让某人去某处/回某处”用 npc。\nNPC：smith=老王（铁匠），apothecary=陈婆（药师），innkeeper=张掌柜（旅店）\n锚点：{anchors}\n活动：smithing=打铁，herbs=晒药，innkeeping=看店，lunch=吃饭，drinking=歇脚，strolling=闲逛，sleep=睡觉，idle=站着\n当前：第{day}天 {hour}:{minute}，天气 {weather}，NPC：{people}\n示例：\n把时间调到晚上八点\ntime 20:00\n快进到明天早上\ntime 07:00\n把时间暂停\nspeed 0\n时间过得快一点\nspeed 10\n下雨\nweather rain\n让老王去酒馆\nnpc smith inn-yard drinking\n让张掌柜回旅店看店\nnpc innkeeper inn innkeeping\n让老王恢复日程\nnpc smith auto\n带我找陈婆\ntp apothecary\n老王现在在干嘛\npeople\n陈婆在干什么\npeople\n<|im_end|>\n<|im_start|>user\n{text}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>")

(define (gm-join xs sep)
  (cond ((null? xs) "")
        ((null? (cdr xs)) (car xs))
        (else (string-append (car xs) sep (gm-join (cdr xs) sep)))))

(define (gm-people-text hour)
  (gm-join
    (map (lambda (npc)
           (let ((plan (npc-plan npc hour)))
             (string-append (symbol->string npc) "="
                            (if (car plan) (car plan) "?")
                            "/" (symbol->string (cadr plan)))))
         *npcs*)
    " "))

(define (gm-clean-plan text)
  (let* ((trimmed (string-trim text))
         (i (string-index trimmed "\n"))
         (first (if i (substring trimmed 0 i) trimmed)))
    (string-trim (string-replace-all first "\"" ""))))

;; ---- deterministic entity repair ---------------------------------------------
;; The 0.6B model is reliable at choosing the command shape, not at copying the
;; names out of the request: with many few-shot examples it sometimes returns
;; the villager or anchor used in an example. These tables let the names that
;; literally appear in the player's text win over whatever the model emitted.

(define *gm-npc-aliases*
  '(("老王" . "smith") ("铁匠" . "smith")
    ("陈婆" . "apothecary") ("药师" . "apothecary")
    ("张掌柜" . "innkeeper") ("掌柜" . "innkeeper")))

(define *gm-anchor-aliases*
  '(("酒馆" . "inn-yard")
    ("客栈" . "inn") ("旅店" . "inn")
    ("铁匠铺" . "smithy-door") ("铁匠家" . "smith-home")
    ("药圃" . "herb-garden") ("药园" . "herb-garden") ("药师家" . "apothecary-home")
    ("掌柜家" . "innkeeper-home")
    ("河边" . "riverbank") ("广场" . "village-square")))

(define *gm-activity-aliases*
  '(("打铁" . "smithing") ("晒药" . "herbs") ("看店" . "innkeeping")
    ("吃饭" . "lunch") ("喝酒" . "drinking") ("歇脚" . "drinking")
    ("闲逛" . "strolling") ("睡觉" . "sleep")))

(define (gm-space? c)
  (or (char=? c #\space) (char=? c #\newline)
      (char=? c #\tab) (char=? c #\return)))

(define (gm-split s)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((>= i (string-length s))
           (reverse (if (> i start) (cons (substring s start i) acc) acc)))
          ((gm-space? (string-ref s i))
           (loop (+ i 1) (+ i 1)
                 (if (> i start) (cons (substring s start i) acc) acc)))
          (else (loop (+ i 1) start acc)))))

(define (gm-set-nth l i v)
  (cond ((null? l) '())
        ((= i 0) (cons v (cdr l)))
        (else (cons (car l) (gm-set-nth (cdr l) (- i 1) v)))))

(define (gm-nth l i)
  (cond ((null? l) #f)
        ((= i 0) (car l))
        (else (gm-nth (cdr l) (- i 1)))))

(define (gm-alias text aliases)
  (cond ((null? aliases) #f)
        ((string-index text (caar aliases)) (cdar aliases))
        (else (gm-alias text (cdr aliases)))))

;; Asking where someone is / what they are doing must never move anyone. If the
;; model answers such a question with a state-changing command, prefer the
;; read-only schedule dump instead.
(define *gm-question-words* '("在哪" "干什么" "做什么" "在干嘛" "谁在" "日程"))

(define (gm-question? text)
  (let loop ((words *gm-question-words*))
    (cond ((null? words) #f)
          ((string-index text (car words)) #t)
          (else (loop (cdr words))))))

(define (gm-fix-npc toks id anchor activity)
  (let* ((t1 (if (and id (>= (length toks) 2)) (gm-set-nth toks 1 id) toks)))
    (cond
      ;; The model sometimes falls back to `auto` even when the request names
      ;; both a place and an activity ("回旅店看店"); restore the full form.
      ((and anchor activity (>= (length t1) 3)
            (string=? (if (gm-nth t1 2) (gm-nth t1 2) "") "auto"))
       (list "npc" (gm-nth t1 1) anchor activity))
      (else
        (let* ((t2 (if (and anchor (>= (length t1) 4)) (gm-set-nth t1 2 anchor) t1)))
          (if (and activity (>= (length t2) 4)) (gm-set-nth t2 3 activity) t2))))))

(define (gm-fix-plan text line)
  (let ((toks (gm-split line)))
    (cond
      ((null? toks) line)
      ((and (gm-question? text)
            (not (string-index text "让"))
            (not (string-index text "把"))
            (member (car toks) '("npc" "tp" "talk" "goto")))
       "people")
      (else
        (let ((cmd (car toks)))
          (cond ((string=? cmd "npc")
                 (gm-join (gm-fix-npc toks
                                     (gm-alias text *gm-npc-aliases*)
                                     (gm-alias text *gm-anchor-aliases*)
                                     (gm-alias text *gm-activity-aliases*))
                          " "))
                ((or (string=? cmd "tp") (string=? cmd "talk"))
                 (gm-join (gm-fix-npc toks (gm-alias text *gm-npc-aliases*) #f #f)
                          " "))
                ((string=? cmd "goto")
                 (let ((a (gm-alias text *gm-anchor-aliases*)))
                   (gm-join (if (and a (>= (length toks) 2))
                                (gm-set-nth toks 1 a)
                                toks)
                            " ")))
                (else line)))))))

(define (gm-build-prompt text)
  (let* ((now (clock-at *tick*)))
    (string-fill *gm-prompt-template*
      (list (cons "{day}" (number->string (car now)))
            (cons "{hour}" (number->string (cadr now)))
            (cons "{minute}" (number->string (caddr now)))
            (cons "{weather}" (symbol->string (current-weather)))
            (cons "{people}" (gm-people-text (cadr now)))
            (cons "{anchors}" (gm-join (map-anchors 'village) " "))
            (cons "{text}" text)))))

(define (game:gm-plan text)
  (if (not (ai-asks?))
      ""
      (gm-fix-plan text
                   (gm-clean-plan (generate-command (gm-build-prompt text) 48)))))

;; Debug hooks for the GM console: inspect the prompt and its token cost.
(define (game:debug-gm-prompt text)
  (gm-build-prompt text))

(define (game:debug-gm-tokens text)
  (vector-length (llm-tokenize *model* (gm-build-prompt text)
                               (list (cons 'parse-special #t)))))

(define (game:debug-gm-raw text)
  (if (not (ai-asks?))
      ""
      (gm-clean-plan (generate-command-free (gm-build-prompt text) 48))))

;; ---- debug clock / weather ---------------------------------------------------
;; Set the absolute clock (day starts at 1) or jump forward by minutes. Both
;; return game:status so the bridge refreshes the HUD from one reply.
;; Ticks are relative to startHour: on day 1 a pre-startHour time clamps to 0.

(define (game:debug-set-time day hour minute)
  (let* ((d (max 1 day))
         (h (max 0 (min 23 hour)))
         (m (max 0 (min 59 minute)))
         (total (+ (* (- d 1) ticks-per-day)
                   (* h ticks-per-hour)
                   (* m ticks-per-minute))))
    (set! *tick* (max 0 (- total (* (start-hour) ticks-per-hour))))
    (run-tick-hooks!)
    (game:status)))

(define (game:debug-advance minutes)
  (set! *tick* (max 0 (+ *tick* (* minutes ticks-per-minute))))
  (run-tick-hooks!)
  (game:status))

;; "" (or anything unrecognised) clears the override and returns to seeded weather.
(define (game:debug-set-weather name)
  (let ((s (if (string? name) name (symbol->string name))))
    (set! *weather-override*
          (if (member s '("sun" "cloud" "rain" "storm" "fog"))
              (string->symbol s)
              #f))
    (game:status)))

;; Samplers need the model handle, so they are built once boot-llm succeeds.
(set! *post-boot-hook*
      (lambda ()
        (set! *gm-smpl* (llm-sampler-new *model*
                                         (list (cons 'temp 0.1)
                                               (cons 'top-k 10)
                                               (cons 'top-p 0.9)
                                               (cons 'penalty-last-n 32)
                                               (cons 'penalty-repeat 1.05)
                                               (cons 'grammar *gm-grammar*))))
        (set! *gm-free-smpl* (llm-sampler-new *model*
                                              (list (cons 'temp 0.1)
                                                    (cons 'top-k 10)
                                                    (cons 'top-p 0.9))))))
