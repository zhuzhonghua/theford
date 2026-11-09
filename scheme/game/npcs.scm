;; npcs.scm — the village roster: ids, canned fallback lines, LLM personas,
;; display names, and the player utterances that feed topic prompts.
;;
;; Keep this file about *who* the NPCs are; conversation flow lives in talk.scm.

(require "game.util")

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

(define (game:npc-ids) *npcs*)
