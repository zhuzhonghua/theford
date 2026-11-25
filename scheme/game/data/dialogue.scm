;; dialogue.scm — shared conversation text: topic menu labels, player
;; utterances, the system instruction and the LLM prompt template.
;;
;; Pure data. The topic menu is an ordered alist ((id . label) ...) because the
;; dialogue HUD renders entries in data order and hash tables have no order.
;; Quest stages start from *default-topics* and append their own entries.
;;
;; Prompt template placeholders are filled by talk.scm once per turn:
;;   {persona} {sys} {quest} {item} {carried} {status} {reason} {hint}
;;   {day} {hour} {minute} {weather} {who} {activity}   <- current situation
;;   {story}      notable story facts, so replies follow the narrative
;;   {history} {player}
;;
;; Weather/activity symbols are turned into player-facing Chinese through the
;; two label tables below; talk.scm falls back to the raw symbol for new values.
;;
;; Data DSL: `table` (util.scm).

(require "game.util")

(define *default-topics*
  '((greet . "打个招呼")
    (village . "聊聊村子")
    (work . "问问活计")))

;; Speaker label for the player inside dialogue history / prompt text.
(define *player-speaker* "玩家")

(define *topic-utterances*
  (table
    (greet = "我路过村子，跟你打个招呼吧。")
    (village = "给我讲讲渡口村的事吧。")
    (work = "你最近手头的活计还顺利么？")))

(define *sys-instruction*
  "你就是这个 NPC。只输出对玩家说的一句台词，不要加引号，不要加名字前缀，只用简短的日常中文，不要思考，不要替玩家说话。可以顺着当前情境自然地提到时辰、天气或手头的活计，一句带过即可，不要生硬报数据。")

;; Situation labels. Keys are the weather/activity symbols used by time.scm and
;; people.scm; values are what the villager would actually say out loud.
(define *weather-labels*
  (table
    (sun = "晴")
    (cloud = "多云")
    (rain = "下雨")
    (storm = "暴雨")
    (fog = "起雾")))

;; State-aware canned greetings: key = npc id, value = table of fact-id -> line.
;; The LLM prompt already carries {story}; this keeps the no-model / canned
;; path just as context-aware instead of repeating the opening line forever.
(define *fact-greetings*
  (table
    (axun/ford.ferry-open
      = "阿笋：船修好了……你没把它拖走。谢谢你。")
    (smith/ford.ferry-open
      = "老王：第一班渡船开出去了，信也送到了。嘿，你我还真把这事办成了。")
    (innkeeper/ford.ferry-open
      = "张掌柜：对岸的客人能过来了，今晚屋里该热闹了。")))

(define *activity-labels*
  (table
    (smithing = "打铁")
    (herbs = "晒药")
    (innkeeping = "看店")
    (lunch = "吃饭")
    (drinking = "歇脚")
    (strolling = "闲逛")
    (loitering = "晃悠")
    (sleep = "睡觉")
    (idle = "发呆")))

(define *prompt-template*
  "<|im_start|>system\n{persona}{sys}<|im_end|>\n<|im_start|>user\n当前任务状态：{quest}\n玩家背包：{item} x{carried}\n刚刚的判定：Scheme 结果={status}，原因={reason}\n{hint}\n当前情境：第{day}天 {hour}:{minute}，天气：{weather}，{who}正在{activity}。\n{story}\n对话记录：\n{history}\n玩家：{player}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>")
