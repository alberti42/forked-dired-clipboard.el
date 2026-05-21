;;; dired-clipboard.el --- Copy and paste Dired files via clipboard -*- lexical-binding: t; -*-

;; Author: kn66
;; Version: 0.1.0
;; Keywords: files, convenience
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; This package adds Dired file clipboard commands:
;;
;; - M-w copies marked files/directories to the clipboard.
;; - C-y pastes files/directories from the clipboard into the current Dired directory.
;; - M-w falls back to the default binding while the region is active.
;; - M-w/C-y fall back to the default bindings while editing file names in WDired.

;;; Code:

(require 'dired)
(require 'dired-aux)
(require 'select)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)

(defvar wdired-mode-map)
(declare-function xselect--encode-string "select"
                  (type str &optional can-modify prefer-string-to-c-string))

(defgroup dired-clipboard nil
  "Copy and paste Dired files via the clipboard."
  :group 'dired
  :prefix "dired-clipboard-")

(defcustom dired-clipboard-recursive-copies 'always
  "How `dired-clipboard-paste' handles directory copies.
The value is bound to `dired-recursive-copies' while pasting."
  :type '(choice (const :tag "Ask" top)
                 (const :tag "Always" always)
                 (const :tag "Never" nil))
  :group 'dired-clipboard)

(defcustom dired-clipboard-keep-marker dired-keep-marker-copy
  "Marker used for files created by `dired-clipboard-paste'."
  :type '(choice (const :tag "Do not mark pasted files" nil)
                 (const :tag "Use current Dired marker" t)
                 (character :tag "Marker character"))
  :group 'dired-clipboard)

(defcustom dired-clipboard-use-wl-copy t
  "Whether to use wl-copy for file clipboard data under PGTK/Wayland.
The PGTK clipboard backend advertises plain text targets for
`gui-set-selection', but GNOME Files needs file clipboard MIME
types such as `x-special/gnome-copied-files'.  When this option is
non-nil and wl-copy is available, `dired-clipboard-copy' starts a
wl-copy process that owns the clipboard with file-copy MIME data.
The MIME type is controlled by `dired-clipboard-wayland-target'.
The plain path list is still kept in the Emacs kill ring for
Dired-to-Dired paste."
  :type 'boolean
  :group 'dired-clipboard)

(defcustom dired-clipboard-wayland-target 'auto
  "File clipboard MIME target used by wl-copy under PGTK/Wayland.
The value `auto' uses the GNOME/Nautilus format on GNOME-like
desktops, and `text/uri-list' on KDE/LXQt and unknown desktops."
  :type '(choice (const :tag "Auto-detect desktop" auto)
                 (const :tag "GNOME/Nautilus format" gnome)
                 (const :tag "text/uri-list" uri-list))
  :group 'dired-clipboard)

(defcustom dired-clipboard-use-native-file-clipboard t
  "Whether to use native file clipboard formats on Windows and macOS.
On Windows this uses the Explorer FileDrop clipboard format through
PowerShell/.NET.  On macOS this uses NSPasteboard file URLs through
osascript and AppleScriptObjC."
  :type 'boolean
  :group 'dired-clipboard)

(defcustom dired-clipboard-powershell-program nil
  "PowerShell executable used for Windows file clipboard integration.
When nil, use the first available executable among powershell.exe,
powershell, pwsh.exe and pwsh."
  :type '(choice (const :tag "Auto-detect" nil)
                 (string :tag "Program"))
  :group 'dired-clipboard)

(defcustom dired-clipboard-osascript-program "osascript"
  "osascript executable used for macOS file clipboard integration."
  :type 'string
  :group 'dired-clipboard)

(defvar dired-clipboard--saved-text-uri-list-converter nil
  "Original `text/uri-list' converter before `dired-clipboard' wraps it.")

(defvar dired-clipboard--wl-copy-process nil
  "Current wl-copy process used to own the Wayland clipboard.")

(defconst dired-clipboard--file-uri-path-chars
  (append url-unreserved-chars '(?/ ?:))
  "Characters left unescaped in file URI paths.")

(defconst dired-clipboard--windows-set-file-drop-script
  "$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
$files = New-Object System.Collections.Specialized.StringCollection
foreach ($line in ([Console]::In.ReadToEnd() -split \"`n\")) {
  $line = $line.Trim()
  if ($line.Length -gt 0) {
    $path = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))
    [void] $files.Add($path)
  }
}
if ($files.Count -eq 0) { exit 1 }
$data = New-Object System.Windows.Forms.DataObject
$data.SetFileDropList($files)
$effect = New-Object System.IO.MemoryStream(,[BitConverter]::GetBytes([UInt32]1))
$data.SetData('Preferred DropEffect', $effect)
[System.Windows.Forms.Clipboard]::SetDataObject($data, $true)"
  "PowerShell script that sets the Windows FileDrop clipboard.")

(defconst dired-clipboard--windows-get-file-drop-script
  "$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
  foreach ($path in [System.Windows.Forms.Clipboard]::GetFileDropList()) {
    [Console]::Out.WriteLine(
      [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($path)))
  }
}"
  "PowerShell script that prints the Windows FileDrop clipboard.")

(defconst dired-clipboard--macos-set-file-urls-script
  "use framework \"AppKit\"
use framework \"Foundation\"
use scripting additions

on run argv
  set urls to current application's NSMutableArray's array()
  repeat with filePath in argv
    set nsPath to current application's NSString's stringWithString:(contents of filePath)
    set fileURL to current application's NSURL's fileURLWithPath:nsPath
    (urls's addObject:fileURL)
  end repeat

  set pasteboard to current application's NSPasteboard's generalPasteboard()
  pasteboard's clearContents()
  if not (pasteboard's writeObjects:urls) then error \"NSPasteboard writeObjects failed\"
end run"
  "AppleScriptObjC script that sets macOS file URLs on NSPasteboard.")

(defconst dired-clipboard--macos-get-file-urls-script
  "use framework \"AppKit\"
use framework \"Foundation\"
use scripting additions

set pasteboard to current application's NSPasteboard's generalPasteboard()
set urlClass to current application's NSURL's class
set classes to current application's NSArray's arrayWithObject:urlClass
set fileOnly to current application's NSNumber's numberWithBool:true
set options to current application's NSDictionary's dictionaryWithObject:fileOnly forKey:(current application's NSPasteboardURLReadingFileURLsOnlyKey)
set urls to pasteboard's readObjectsForClasses:classes options:options
if urls is missing value then return \"\"

set paths to {}
repeat with fileURL in urls
  set end of paths to (fileURL's |path|()) as text
end repeat
set AppleScript's text item delimiters to linefeed
return paths as text"
  "AppleScriptObjC script that prints macOS file URLs from NSPasteboard.")

(defun dired-clipboard--call-process (program input &rest args)
  "Run PROGRAM with ARGS and optional INPUT, returning stdout on success."
  (when-let ((executable (executable-find program)))
    (with-temp-buffer
      (let* ((output (current-buffer))
             (status
              (if input
                  (with-temp-buffer
                    (insert input)
                    (apply #'call-process-region
                           (point-min) (point-max)
                           executable nil output nil args))
                (apply #'call-process executable nil output nil args))))
        (when (and (integerp status) (zerop status))
          (buffer-string))))))

(defun dired-clipboard--base64-encode-utf8 (text)
  "Return TEXT encoded as one unwrapped base64 UTF-8 string."
  (base64-encode-string (encode-coding-string text 'utf-8) t))

(defun dired-clipboard--base64-decode-utf8 (text)
  "Return base64 TEXT decoded as UTF-8."
  (decode-coding-string (base64-decode-string text) 'utf-8))

(defun dired-clipboard--base64-lines (strings)
  "Return STRINGS encoded as newline-separated base64 UTF-8."
  (concat (mapconcat #'dired-clipboard--base64-encode-utf8 strings "\n")
          "\n"))

(defun dired-clipboard--decode-base64-lines (text)
  "Return newline-separated base64 UTF-8 TEXT as strings."
  (let (strings)
    (dolist (line (dired-clipboard--lines text) (nreverse strings))
      (when (and (zerop (% (length line) 4))
                 (string-match-p "\\`[[:alnum:]+/=]+\\'" line))
        (when-let ((string (ignore-errors
                             (dired-clipboard--base64-decode-utf8 line))))
          (push string strings))))))

(defun dired-clipboard--powershell-program ()
  "Return the PowerShell executable used for Windows clipboard integration."
  (or dired-clipboard-powershell-program
      (executable-find "powershell.exe")
      (executable-find "powershell")
      (executable-find "pwsh.exe")
      (executable-find "pwsh")))

(defun dired-clipboard--powershell-encoded-command (script)
  "Return SCRIPT encoded for PowerShell -EncodedCommand."
  (base64-encode-string (encode-coding-string script 'utf-16le) t))

(defun dired-clipboard--call-powershell (script &optional input)
  "Run PowerShell SCRIPT with optional INPUT, returning stdout on success."
  (when-let ((program (dired-clipboard--powershell-program)))
    (dired-clipboard--call-process
     program input
     "-NoLogo" "-NoProfile" "-NonInteractive" "-STA"
     "-OutputFormat" "Text" "-EncodedCommand"
     (dired-clipboard--powershell-encoded-command script))))

(defun dired-clipboard--call-osascript (script &rest args)
  "Run AppleScript SCRIPT with ARGS, returning stdout on success."
  (apply #'dired-clipboard--call-process
         dired-clipboard-osascript-program nil
         "-e" script args))

(defun dired-clipboard--selection-target-value (target value)
  "Return TARGET text property from selection VALUE."
  (and (stringp value)
       (get-text-property 0 target value)))

(defun dired-clipboard--clipboard-target-available-p (selection type value)
  "Return non-nil if VALUE provides TYPE for the CLIPBOARD SELECTION."
  (and (eq selection 'CLIPBOARD)
       (dired-clipboard--selection-target-value type value)))

(defun dired-clipboard--local-files (files)
  "Return local expanded file names from FILES."
  (let (local-files)
    (dolist (file files (nreverse local-files))
      (unless (file-remote-p file)
        (push (expand-file-name file) local-files)))))

(defun dired-clipboard--uris-for-files (files)
  "Return file URIs for local FILES."
  (let (uris)
    (dolist (file files (nreverse uris))
      (push (dired-clipboard--file-to-uri file) uris))))

(defun dired-clipboard--convert-clipboard-target (_selection type value)
  "Convert VALUE to clipboard target TYPE."
  (when-let ((text (dired-clipboard--selection-target-value type value)))
    (cons type (cdr (xselect--encode-string 'TEXT text t)))))

(defun dired-clipboard--call-saved-text-uri-list-converter
    (selection type value predicate)
  "Call the saved `text/uri-list' converter for SELECTION, TYPE and VALUE.
When PREDICATE is non-nil, call the saved predicate instead."
  (let ((converter dired-clipboard--saved-text-uri-list-converter))
    (cond
     ((and predicate (consp converter) (functionp (car converter)))
      (funcall (car converter) selection type value))
     ((and (not predicate) (consp converter) (functionp (cdr converter)))
      (funcall (cdr converter) selection type value))
     ((and (not predicate) (functionp converter))
      (funcall converter selection type value)))))

(defun dired-clipboard--text-uri-list-available-p (selection type value)
  "Return non-nil when `text/uri-list' is available for SELECTION."
  (or (dired-clipboard--clipboard-target-available-p selection type value)
      (dired-clipboard--call-saved-text-uri-list-converter
       selection type value t)))

(defun dired-clipboard--convert-text-uri-list (selection type value)
  "Convert VALUE to `text/uri-list' for SELECTION."
  (or (dired-clipboard--convert-clipboard-target selection type value)
      (dired-clipboard--call-saved-text-uri-list-converter
       selection type value nil)))

(defun dired-clipboard--install-selection-converters ()
  "Install clipboard converters used by external file managers."
  (unless dired-clipboard--saved-text-uri-list-converter
    (setq dired-clipboard--saved-text-uri-list-converter
          (cdr (assq 'text/uri-list selection-converter-alist))))
  (setq selection-converter-alist
        (assq-delete-all 'x-special/gnome-copied-files
                         selection-converter-alist))
  (push '(x-special/gnome-copied-files
          . (dired-clipboard--clipboard-target-available-p
             . dired-clipboard--convert-clipboard-target))
        selection-converter-alist)
  (let ((cell (assq 'text/uri-list selection-converter-alist)))
    (if cell
        (setcdr cell
                '(dired-clipboard--text-uri-list-available-p
                  . dired-clipboard--convert-text-uri-list))
      (push '(text/uri-list
              . (dired-clipboard--text-uri-list-available-p
                 . dired-clipboard--convert-text-uri-list))
            selection-converter-alist))))

(defun dired-clipboard--wl-copy-available-p ()
  "Return non-nil if wl-copy should be used for the current display."
  (and dired-clipboard-use-wl-copy
       (featurep 'pgtk)
       (getenv "WAYLAND_DISPLAY")
       (executable-find "wl-copy")))

(defun dired-clipboard--desktop-match-p (&rest names)
  "Return non-nil if current desktop name matches any of NAMES."
  (let ((desktop (or (getenv "XDG_CURRENT_DESKTOP")
                     (getenv "DESKTOP_SESSION")
                     "")))
    (catch 'match
      (dolist (name names nil)
        (when (string-match-p (regexp-quote name) desktop)
          (throw 'match t))))))

(defun dired-clipboard--wayland-target ()
  "Return the wl-copy MIME target kind for the current desktop."
  (pcase dired-clipboard-wayland-target
    ('gnome 'gnome)
    ('uri-list 'uri-list)
    (_ (cond
        ((dired-clipboard--desktop-match-p "GNOME" "Cinnamon" "XFCE"
                                           "MATE" "Budgie" "Unity"
                                           "Pantheon")
         'gnome)
        ((dired-clipboard--desktop-match-p "KDE" "Plasma" "LXQt")
         'uri-list)
        (t 'uri-list)))))

(defun dired-clipboard--wayland-mime-and-data (gnome-list uri-list)
  "Return a cons of MIME type and data for GNOME-LIST and URI-LIST."
  (pcase (dired-clipboard--wayland-target)
    ('gnome (cons "x-special/gnome-copied-files" gnome-list))
    (_ (cons "text/uri-list" uri-list))))

(defun dired-clipboard--stop-wl-copy ()
  "Stop the wl-copy process owned by `dired-clipboard'."
  (when (process-live-p dired-clipboard--wl-copy-process)
    (delete-process dired-clipboard--wl-copy-process))
  (setq dired-clipboard--wl-copy-process nil))

(defun dired-clipboard--set-wayland-file-clipboard (gnome-list uri-list)
  "Set Wayland file clipboard data to GNOME-LIST or URI-LIST using wl-copy."
  (when (dired-clipboard--wl-copy-available-p)
    (dired-clipboard--stop-wl-copy)
    (pcase-let* ((`(,mime-type . ,data)
                  (dired-clipboard--wayland-mime-and-data gnome-list uri-list))
                 (process
                  (make-process
                   :name "dired-clipboard-wl-copy"
                   :command (list "wl-copy" "--foreground" "--type" mime-type)
                   :connection-type 'pipe
                   :noquery t)))
      (setq dired-clipboard--wl-copy-process process)
      (process-send-string process data)
      (process-send-eof process)
      process)))

(defun dired-clipboard--lines (text)
  "Return non-empty lines from TEXT."
  (when (stringp text)
    (let (lines)
      (dolist (line (split-string text "\n" t) (nreverse lines))
        (when (and (> (length line) 0)
                   (= (aref line (1- (length line))) ?\r))
          (setq line (substring line 0 -1)))
        (unless (string-empty-p line)
          (push line lines))))))

(defun dired-clipboard--file-to-uri (file)
  "Return a file URI for local FILE."
  (let ((path (expand-file-name file)))
    (if (and (eq system-type 'windows-nt)
             (string-match "\\`//\\([^/]+\\)\\(/.*\\)" path))
        (concat "file://"
                (match-string 1 path)
                (url-hexify-string
                 (match-string 2 path)
                 dired-clipboard--file-uri-path-chars))
      (concat "file://"
              (unless (string-prefix-p "/" path) "/")
              (url-hexify-string path dired-clipboard--file-uri-path-chars)))))

(defun dired-clipboard--uri-to-file (uri)
  "Return a local file name from file URI."
  (when (string-match-p "\\`file:" uri)
    (let* ((url (url-generic-parse-url uri))
           (host (url-host url))
           (path (url-filename url)))
      (when (and path
                 (or (eq system-type 'windows-nt)
                     (null host)
                     (string-empty-p host)
                     (string= host "localhost")))
        (setq path (url-unhex-string path 'utf-8))
        (when (eq system-type 'windows-nt)
          (cond
           ((and host
                 (not (string-empty-p host))
                 (not (string= host "localhost")))
            (setq path (concat "//" host path)))
           ((string-match-p "\\`/[[:alpha:]]:" path)
            (setq path (substring path 1)))))
        path))))

(defun dired-clipboard--parse-uri-list (text)
  "Return local file names from a text/uri-list TEXT."
  (let (files)
    (dolist (line (dired-clipboard--lines text) (nreverse files))
      (unless (or (string-empty-p line)
                  (eq (aref line 0) ?#))
        (when-let ((file (dired-clipboard--uri-to-file line)))
          (push file files))))))

(defun dired-clipboard--parse-gnome-files (text)
  "Return local file names from GNOME/Nautilus clipboard TEXT."
  (let ((lines (dired-clipboard--lines text)))
    (when (string= (car lines) "x-special/nautilus-clipboard")
      (setq lines (cdr lines)))
    (when (member (car lines) '("copy" "cut"))
      (dired-clipboard--parse-uri-list
       (mapconcat #'identity (cdr lines) "\n")))))

(defun dired-clipboard--parse-path-list (text)
  "Return absolute file names from newline-separated TEXT."
  (let (files)
    (dolist (line (dired-clipboard--lines text) (nreverse files))
      (when (file-name-absolute-p line)
        (push (expand-file-name line) files)))))

(defun dired-clipboard--selection (data-type)
  "Return clipboard selection converted to DATA-TYPE, or nil."
  (when (fboundp 'gui-get-selection)
    (ignore-errors
      (gui-get-selection 'CLIPBOARD data-type))))

(defun dired-clipboard--current-kill ()
  "Return the latest kill-ring entry, or nil."
  (ignore-errors
    (current-kill 0 t)))

(defun dired-clipboard--existing-files (files)
  "Return existing FILES without duplicates."
  (let (seen existing)
    (dolist (file files (nreverse existing))
      (when (and (file-exists-p file)
                 (not (member file seen)))
        (push file seen)
        (push file existing)))))

(defun dired-clipboard--set-windows-file-clipboard (files)
  "Set the Windows Explorer file clipboard to FILES."
  (when (and dired-clipboard-use-native-file-clipboard
             (eq system-type 'windows-nt)
             files)
    (dired-clipboard--call-powershell
     dired-clipboard--windows-set-file-drop-script
     (dired-clipboard--base64-lines files))))

(defun dired-clipboard--windows-files-from-clipboard ()
  "Return file names from the Windows Explorer file clipboard."
  (when (and dired-clipboard-use-native-file-clipboard
             (eq system-type 'windows-nt))
    (when-let ((output (dired-clipboard--call-powershell
                        dired-clipboard--windows-get-file-drop-script)))
      (dired-clipboard--decode-base64-lines output))))

(defun dired-clipboard--set-macos-file-clipboard (files)
  "Set the macOS Finder file clipboard to FILES."
  (when (and dired-clipboard-use-native-file-clipboard
             (eq system-type 'darwin)
             files
             (executable-find dired-clipboard-osascript-program))
    (apply #'dired-clipboard--call-osascript
           dired-clipboard--macos-set-file-urls-script
           files)))

(defun dired-clipboard--macos-files-from-clipboard ()
  "Return file names from the macOS Finder file clipboard."
  (when (and dired-clipboard-use-native-file-clipboard
             (eq system-type 'darwin)
             (executable-find dired-clipboard-osascript-program))
    (when-let ((output (dired-clipboard--call-osascript
                        dired-clipboard--macos-get-file-urls-script)))
      (dired-clipboard--lines output))))

(defun dired-clipboard--set-native-file-clipboard (files)
  "Set the native OS file clipboard to FILES."
  (pcase system-type
    ('windows-nt (dired-clipboard--set-windows-file-clipboard files))
    ('darwin (dired-clipboard--set-macos-file-clipboard files))))

(defun dired-clipboard--native-files-from-clipboard ()
  "Return files from the native OS file clipboard."
  (pcase system-type
    ('windows-nt (dired-clipboard--windows-files-from-clipboard))
    ('darwin (dired-clipboard--macos-files-from-clipboard))))

(defun dired-clipboard--files-from-clipboard ()
  "Return existing files/directories represented by the clipboard."
  (let* ((native-files (dired-clipboard--native-files-from-clipboard))
         (gnome (dired-clipboard--selection 'x-special/gnome-copied-files))
         (uri-list (dired-clipboard--selection 'text/uri-list))
         (text (or (dired-clipboard--selection 'UTF8_STRING)
                   (dired-clipboard--selection 'STRING)
                   (dired-clipboard--current-kill)))
         (files (or native-files
                    (dired-clipboard--parse-gnome-files gnome)
                    (dired-clipboard--parse-gnome-files text)
                    (dired-clipboard--parse-uri-list uri-list)
                    (dired-clipboard--parse-path-list text))))
    (dired-clipboard--existing-files files)))

(defun dired-clipboard--copy-files (files)
  "Copy FILES to the kill ring and system clipboard."
  (let* ((text (mapconcat #'identity files "\n"))
         (local-files (dired-clipboard--local-files files))
         (local-uris (dired-clipboard--uris-for-files local-files))
         (uri-list (when local-uris
                     (concat (mapconcat #'identity local-uris "\r\n") "\r\n")))
         (gnome-list (when local-uris
                       ;; Nautilus rejects empty lines in this MIME payload.
                       (concat "copy\n" (mapconcat #'identity local-uris "\n"))))
         (selection (copy-sequence text))
         clipboard-owned)
    (when local-uris
      (dired-clipboard--install-selection-converters)
      (add-text-properties
       0 (length selection)
       `(text/uri-list ,uri-list
                       x-special/gnome-copied-files ,gnome-list)
       selection))
    (setq clipboard-owned
          (and local-uris
               (or (dired-clipboard--set-native-file-clipboard local-files)
                   (dired-clipboard--set-wayland-file-clipboard gnome-list uri-list))))
    (if clipboard-owned
        (let ((interprogram-cut-function nil))
          (kill-new text))
      (dired-clipboard--stop-wl-copy)
      (kill-new text)
      (when (fboundp 'gui-set-selection)
        (ignore-errors
          (gui-set-selection 'CLIPBOARD selection))))))

(add-hook 'kill-emacs-hook #'dired-clipboard--stop-wl-copy)

(defun dired-clipboard--ensure-not-wdired ()
  "Signal an error when called from WDired."
  (when (derived-mode-p 'wdired-mode)
    (user-error "M-w/C-y are disabled while editing Dired entries")))

(defun dired-clipboard--region-active-p ()
  "Return non-nil when a non-empty region is active."
  (and (bound-and-true-p mark-active)
       (mark t)
       (> (region-end) (region-beginning))))

;;;###autoload
(defun dired-clipboard-copy ()
  "Copy marked Dired files/directories to the clipboard."
  (interactive nil dired-mode)
  (dired-clipboard--ensure-not-wdired)
  (when (dired-clipboard--region-active-p)
    (user-error "Dired file copy is disabled while the region is active"))
  (let ((files (dired-get-marked-files
                nil 'marked nil nil
                "No marked files")))
    (dired-clipboard--copy-files files)
    (message "%d item%s copied to clipboard"
             (length files)
             (if (= (length files) 1) "" "s"))))

;;;###autoload
(defun dired-clipboard-paste ()
  "Paste files/directories represented by the clipboard into Dired."
  (interactive nil dired-mode)
  (dired-clipboard--ensure-not-wdired)
  (let ((files (dired-clipboard--files-from-clipboard))
        (target (file-name-as-directory (dired-current-directory)))
        (dired-recursive-copies dired-clipboard-recursive-copies))
    (unless files
      (user-error "Clipboard does not contain pasteable files or directories"))
    (dired-create-files
     #'dired-copy-file
     "Paste"
     files
     (lambda (from)
       (expand-file-name
        (file-name-nondirectory (directory-file-name from))
        target))
     dired-clipboard-keep-marker)))

(defun dired-clipboard--disabled-in-wdired ()
  "Disable file clipboard commands while editing Dired entries."
  (interactive)
  (user-error "M-w/C-y are disabled while editing Dired entries"))

(defun dired-clipboard--copy-key-binding (&optional _)
  "Return the M-w binding for the current Dired state."
  (if (or (derived-mode-p 'wdired-mode)
          (dired-clipboard--region-active-p))
      nil
    #'dired-clipboard-copy))

(defun dired-clipboard--paste-key-binding (&optional _)
  "Return the C-y binding for the current Dired state."
  (if (derived-mode-p 'wdired-mode)
      nil
    #'dired-clipboard-paste))

(defvar dired-clipboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-w")
                `(menu-item "" nil :filter ,#'dired-clipboard--copy-key-binding))
    (define-key map (kbd "C-y")
                `(menu-item "" nil :filter ,#'dired-clipboard--paste-key-binding))
    map)
  "Keymap for `dired-clipboard-mode'.")

;;;###autoload
(define-minor-mode dired-clipboard-mode
  "Use M-w/C-y to copy and paste files in Dired."
  :lighter nil
  :keymap dired-clipboard-mode-map)

(with-eval-after-load 'wdired
  (when (eq (lookup-key wdired-mode-map (kbd "M-w"))
            #'dired-clipboard--disabled-in-wdired)
    (define-key wdired-mode-map (kbd "M-w") nil))
  (when (eq (lookup-key wdired-mode-map (kbd "C-y"))
            #'dired-clipboard--disabled-in-wdired)
    (define-key wdired-mode-map (kbd "C-y") nil)))

(provide 'dired-clipboard)

;;; dired-clipboard.el ends here
