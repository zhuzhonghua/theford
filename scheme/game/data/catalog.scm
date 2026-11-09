;; catalog.scm — asset path mapping (data only).
;;
;; Maps game-side keys (npc ids, music keys, sfx events, item types) to
;; asset paths relative to res://. Tile → texture mapping stays in
;; world_tileset.tres; this file only covers characters, facesets, music,
;; sfx and item sprites.
;;
;; Replacing an asset means editing the path here — no GDScript change.
;; Godot reads these via the bridge (catalog-faceset, catalog-music, …).

(require "game.util")

(define *catalog*
  (list
    ;; characters: id -> (spritesheet faceset) paths relative to res://
    (cons "characters"
      (list
        (cons "player"
          (list (cons 'spritesheet "assets/na/Actor/Character/NinjaRed/SpriteSheet.png")
                (cons 'faceset "")))
        (cons "smith"
          (list (cons 'spritesheet "assets/na/Actor/Character/Villager/SpriteSheet.png")
                (cons 'faceset "assets/lsw/Faces/Actor/Character/Villager/Faceset.png")))
        (cons "apothecary"
          (list (cons 'spritesheet "assets/na/Actor/Character/Woman/SpriteSheet.png")
                (cons 'faceset "assets/lsw/Faces/Actor/Character/Woman/Faceset.png")))
        (cons "innkeeper"
          (list (cons 'spritesheet "assets/na/Actor/Character/Villager2/SpriteSheet.png")
                (cons 'faceset "assets/lsw/Faces/Actor/Character/Villager2/Faceset.png")))))
    ;; music: key -> path
    (cons "music"
      (list
        (cons "village" "assets/na/Audio/Musics/4 - Village.ogg")))
    ;; sfx: event key -> path (wired in the audio phase)
    (cons "sfx" '())
    ;; items: type sprite key -> path (wired in the inventory phase)
    (cons "items" '())))

;; (catalog-section key) — the alist for a top-level section, or #f.
(define (catalog-section key)
  (alist-get *catalog* key))

;; (catalog-character id field) — path string for a character's field
;; ('spritesheet | 'faceset), or #f.
(define (catalog-character id field)
  (let ((c (catalog-section "characters")))
    (and c (let ((entry (alist-get c id)))
             (and entry (alist-get entry field))))))

;; (catalog-music key) — path string for a music track, or #f.
(define (catalog-music key)
  (let ((m (catalog-section "music")))
    (and m (alist-get m key))))

;; (catalog-sfx key) — path string for a sound effect, or #f.
(define (catalog-sfx key)
  (let ((s (catalog-section "sfx")))
    (and s (alist-get s key))))

;; Bridge-visible wrappers (Godot calls game:catalog-*).
(define (game:catalog-music key) (catalog-music key))
(define (game:catalog-faceset id) (catalog-character id 'faceset))
(define (game:catalog-spritesheet id) (catalog-character id 'spritesheet))
(define (game:catalog-sfx key) (catalog-sfx key))

;; (game:debug-catalog) — whole catalog, for the 1.6 smoke test.
(define (game:debug-catalog)
  *catalog*)
