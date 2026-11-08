;; map.scm — The Ford(渡口) 地图生成。
;;
;; 地图由代码生成，不是手写网格：确定性、可参数化、可重放。
;; 尺寸：48 x 30 格。
;;
;; 图例： T 树(阻挡)  t 灌木(阻挡)  . 草地  = 道路  ~ 水(阻挡)
;;
;; 由 main.scm 通过 (require "game.map") 载入，导出：
;;   (game:map-rows) -> ("TTT...." ...) 共 *map-height* 行

(define *map-width* 48)
(define *map-height* 30)

(define *road-x* 23)      ; 南北向道路占 23、24 两列
(define *road-y* 14)      ; 东西向道路
(define *river-top* 25)   ; 底部 5 行是河

;; 避免依赖字符字面量的解析细节，直接从一个字符串取符号。
(define *glyphs* (string->list "Tt.~="))
(define (glyph i) (list-ref *glyphs* i))

(define (on-road? x)
  (and (>= x *road-x*) (<= x (+ *road-x* 1))))

;; 灌木的散布：草甸、沼泽、普通草地各用一个确定性的取模图案。
(define (bush? x y)
  (cond
    ((and (>= x 6) (<= x 16) (>= y 4) (<= y 10)) (= (modulo (+ (* x 3) y) 7) 0))
    ((and (>= x 32) (<= x 44) (>= y 18) (<= y 23)) (= (modulo (+ x (* y 2)) 6) 0))
    (else (= (modulo (+ (* x 7) (* y 3)) 23) 0))))

;; 单个格子：先满足道路/河，再铺外圈树林，最后才是灌木和草地。
(define (map-cell x y)
  (cond
    ((>= y *river-top*) (if (on-road? x) (glyph 4) (glyph 3)))
    ((or (on-road? x) (= y *road-y*)) (glyph 4))
    ((or (< x 3) (>= x (- *map-width* 3)) (< y 2)) (glyph 0))
    ((bush? x y) (glyph 1))
    (else (glyph 2))))

(define (map-row y)
  (let loop ((x 0) (acc '()))
    (if (= x *map-width*)
        (list->string (reverse acc))
        (loop (+ x 1) (cons (map-cell x y) acc)))))

(define (game:map-rows)
  (let loop ((y 0) (acc '()))
    (if (= y *map-height*)
        (reverse acc)
        (loop (+ y 1) (cons (map-row y) acc)))))
