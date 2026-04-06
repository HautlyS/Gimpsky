;; Whisk AI Tools - GIMP Script-Fu Plugin
;;
;; Simple integration that calls the bridge server via curl.
;; The bridge server must be running and configured with your cookie.
;;
;; Installation:
;;   This file should be in ~/.config/GIMP/2.10/scripts/
;;   Restart GIMP or use Filters > Script-Fu > Refresh Scripts
;;
;; Menus appear under: Filters > Whisk AI

;; Generate Image from Prompt
(define (whisk-ai-generate prompt seed)
  "Generate an image from text prompt using Whisk AI"
  (let* ((cmd (string-append
               "curl -s -X POST http://127.0.0.1:9876/generate "
               "-H 'Content-Type: application/json' "
               "-d '{\"prompt\":\"" prompt "\",\"seed\":" (number->string seed) "}' "
               "> /dev/null 2>&1 &")))
    (system cmd)
    (gimp-message (string-append "Whisk AI: Generation started for '" prompt "'\nCheck /opt/whisk-gimp/output/ in a few minutes"))))

;; Refine Current Image
(define (whisk-ai-refine image drawable edit-prompt)
  "Refine/edit the current image using Whisk AI"
  (let* ((temp-file "/tmp/whisk-refine-input.png"))
    ;; Export current image
    (file-png-save-defaults RUN-NONINTERACTIVE image drawable temp-file temp-file)
    ;; Launch background script
    (let* ((cmd (string-append
                 "(python3 -c \""
                 "import json,base64,urllib.request,os;"
                 "c=json.load(open(os.path.expanduser('~/.config/whisk-gimp/config.json'))) if os.path.exists(os.path.expanduser('~/.config/whisk-gimp/config.json')) else {};"
                 "ck=c.get('cookie','');"
                 "b64='data:image/png;base64,'+base64.b64encode(open('" temp-file "','rb').read()).decode();"
                 "d1=json.dumps({'cookie':ck,'base64Image':b64,'count':1}).encode();"
                 "r1=json.loads(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:9876/caption',d1,{'Content-Type':'application/json'}),timeout=30).read());"
                 "cap=r1.get('captions',['Image'])[0];"
                 "d2=json.dumps({'cookie':ck,'projectName':'GIMP'}).encode();"
                 "r2=json.loads(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:9876/project',d2,{'Content-Type':'application/json'}),timeout=30).read());"
                 "pid=r2.get('projectId','');"
                 "d3=json.dumps({'cookie':ck,'base64Image':b64,'caption':cap,'category':'SUBJECT','projectId':pid}).encode();"
                 "r3=json.loads(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:9876/upload',d3,{'Content-Type':'application/json'}),timeout=60).read());"
                 "mid=r3.get('uploadMediaGenerationId','');"
                 "d4=json.dumps({'cookie':ck,'mediaGenerationId':mid,'editPrompt':'" edit-prompt "'}).encode();"
                 "urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:9876/refine',d4,{'Content-Type':'application/json'}),timeout=180);"
                 "os.remove('" temp-file "')"
                 "\" > /dev/null 2>&1 &)" )))
      (system cmd))
    (gimp-message (string-append "Whisk AI: Refinement started for '" edit-prompt "'"))))

;; Generate Caption for Current Image
(define (whisk-ai-caption image drawable count)
  "Generate captions for the current image"
  (let* ((temp-file "/tmp/whisk-caption-input.png"))
    ;; Export current image
    (file-png-save-defaults RUN-NONINTERACTIVE image drawable temp-file temp-file)
    ;; Launch background script
    (let* ((cmd (string-append
                 "(python3 -c \""
                 "import json,base64,urllib.request,os;"
                 "c=json.load(open(os.path.expanduser('~/.config/whisk-gimp/config.json'))) if os.path.exists(os.path.expanduser('~/.config/whisk-gimp/config.json')) else {};"
                 "ck=c.get('cookie','');"
                 "b64='data:image/png;base64,'+base64.b64encode(open('" temp-file "','rb').read()).decode();"
                 "d=json.dumps({'cookie':ck,'base64Image':b64,'count':" (number->string count) "}).encode();"
                 "r=json.loads(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:9876/caption',d,{'Content-Type':'application/json'}),timeout=60).read());"
                 "caps=r.get('captions',[]);"
                 "print('\\n'.join([f'{i+1}. {x}' for i,x in enumerate(caps)]));"
                 "os.remove('" temp-file "')"
                 "\" 2>/tmp/whisk-caption.log)" )))
      (system cmd))
    (gimp-message (string-append "Whisk AI: Caption generation started"))))

;; Open Latest Generated Image
(define (whisk-ai-open-latest)
  "Open the latest generated image"
  (let* ((files (cadr (file-glob "/opt/whisk-gimp/output/*.png" 1))))
    (if (null? files)
        (gimp-message "Whisk AI: No generated images found in /opt/whisk-gimp/output/")
        (let* ((latest (car (sort files string>?)))
               (result (file-png-load RUN-INTERACTIVE latest latest)))
          (gimp-display-new (car result))
          (gimp-message (string-append "Whisk AI: Opened " latest))))))

;; ============================================================================
;; Procedure Registration
;; ============================================================================

(script-fu-register "whisk-ai-generate"
                    "<Image>/Filters/Whisk AI/_Generate from Prompt..."
                    "Generate an image using Whisk AI"
                    "Whisk AI"
                    "MIT"
                    "2024"
                    ""
                    SF-STRING "Prompt:" "A beautiful landscape"
                    SF-ADJUSTMENT "Seed:" '(0 0 999999 1 10 0 1))

(script-fu-register "whisk-ai-refine"
                    "<Image>/Filters/Whisk AI/_Refine Image..."
                    "Refine/edit image with Whisk AI"
                    "Whisk AI"
                    "MIT"
                    "2024"
                    "RGB*, GRAY*"
                    SF-IMAGE "Image" 0
                    SF-DRAWABLE "Drawable" 0
                    SF-STRING "Edit Instruction:" "Make it snowy")

(script-fu-register "whisk-ai-caption"
                    "<Image>/Filters/Whisk AI/Generate _Caption..."
                    "Generate captions for image"
                    "Whisk AI"
                    "MIT"
                    "2024"
                    "RGB*, GRAY*"
                    SF-IMAGE "Image" 0
                    SF-DRAWABLE "Drawable" 0
                    SF-ADJUSTMENT "Caption Count:" '(3 1 8 1 1 0 1))

(script-fu-register "whisk-ai-open-latest"
                    "<Image>/Filters/Whisk AI/Open _Latest Generated Image"
                    "Open latest generated image"
                    "Whisk AI"
                    "MIT"
                    "2024"
                    "")
