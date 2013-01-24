;;;;; Minimal life-support for testing ASDF from a blank Lisp image.
#|
Some constraints:
* We cannot rely on any test library that could be loaded by ASDF.
 And we cannot even rely on ASDF being present until we load it.
 But we *can* rely on ASDF being present *after* we load it.
* evaluating this file MUST NOT print anything,
 because we use it in the forward-ref test to check that nothing is printed.
* We make sure that none of our symbols clash with asdf/driver or asdf,
 so we may use-package them during testing.
|#

(defpackage :asdf-test
  (:use :common-lisp)
  (:export
   #:asym #:acall
   #:*test-directory* #:*asdf-directory*
   #:load-asdf #:maybe-compile-asdf
   #:load-asdf-lisp #:compile-asdf #:load-asdf-fasl
   #:compile-load-asdf #:load-asdf-system #:clean-load-asdf-system
   #:register-directory #:load-test-system
   #:with-test #:test-asdf #:debug-asdf
   #:assert-compare
   #:assert-equal
   #:leave-test #:def-test-system
   #:action-name #:in-plan-p
   #:test-source #:test-fasl #:resolve-output #:output-location
   #:quietly))

(in-package :asdf-test)

(declaim (optimize (speed 2) (safety 3) #-(or allegro gcl) (debug 3)
		   #+(or cmu scl) (c::brevity 2)))
(proclaim '(optimize (speed 2) (safety 3) #-(or allegro gcl) (debug 3)
		     #+(or cmu scl) (c::brevity 2)))

(defvar *trace-symbols*
  `(;; If you want to trace some stuff while debugging ASDF,
    ;; here's a nice place to say what.
    ;; These string designators will be interned in ASDF after it is loaded.
    
    ;;#+ecl ,@'( :perform :input-files :output-files :compile-file* :compile-file-pathname* :load*)
    ))

(defvar *debug-asdf* nil)
(defvar *quit-when-done* t)

(defun verbose (&optional (verbose t) (print verbose))
  (setf *load-verbose* verbose *compile-verbose* verbose)
  (setf *load-print* print *compile-print* print))

(verbose nil)

;;; Minimal compatibility layer
(eval-when (:compile-toplevel :load-toplevel :execute)
  #+allegro
  (setf excl:*warn-on-nested-reader-conditionals* nil
        excl::*autoload-package-name-alist*
        (remove "asdf" excl::*autoload-package-name-alist*
                :test 'equalp :key 'car)) ; We need that BEFORE any mention of package ASDF.
  #+cmucl (setf ext:*gc-verbose* nil)
  #+gcl
  (when (and (= system::*gcl-major-version* 2)
             (= system::*gcl-minor-version* 6))
    (pushnew :gcl2.6 *features*)
    (shadowing-import 'system:*load-pathname* :asdf-test))
  #+lispworks
  (setf system:*stack-overflow-behaviour* :warn))

#+(or gcl genera)
(unless (fboundp 'ensure-directories-exist)
  (defun ensure-directories-exist (path)
    #+genera (fs:create-directories-recursively (pathname path))
    #+gcl (lisp:system (format nil "mkdir -p ~S"
                               (namestring (make-pathname :name nil :type nil :defaults path))))))

;;; Survival utilities
(defun asym (name)
  (let ((asdf (find-package :asdf)))
    (unless asdf (error "Can't find package ASDF"))
    (or (find-symbol (string name) asdf)
        (error "Can't find symbol ~A in ASDF" name))))
(defun acall (name &rest args)
  (apply (asym name) args))

(defun finish-outputs* ()
  (loop :for s :in (list *standard-output* *error-output* *trace-output* *debug-io*)
        :do (finish-output s)))
(defun redirect-outputs ()
  (finish-outputs*)
  (setf *error-output* *standard-output*
        *trace-output* *standard-output*))

(redirect-outputs) ;; Put everything on standard output, for the sake of scripts

;;; First, some pathname madness.
;; We can't use goodies from asdf/pathnames because ASDF isn't loaded yet.
;; We still want to work despite and host/device funkiness,
;; so we do it the hard way.
(defparameter *test-directory*
  (truename
   (make-pathname :name nil :type nil :version nil
                  :defaults (or *load-pathname* *compile-file-pathname*))))
(defun make-sub-pathname (&rest keys &key defaults &allow-other-keys)
  (merge-pathnames (apply 'make-pathname keys) defaults))
(defun relative-dir (&rest dir) #-gcl (cons ':relative dir) #+gcl dir)
(defun back-dir () #-gcl :back #+gcl :parent)
(defparameter *asdf-directory*
  (truename (make-sub-pathname :directory (relative-dir (back-dir)) :defaults *test-directory*)))
(defparameter *build-directory*
  (make-sub-pathname :directory (relative-dir "build") :defaults *asdf-directory*))
(defparameter *implementation*
  (or #+allegro
      (ecase excl:*current-case-mode*
        (:case-sensitive-lower :mlisp)
        (:case-insensitive-upper :alisp))
      #+armedbear :abcl
      #+clisp :clisp
      #+clozure :ccl
      #+cmu :cmucl
      #+corman :cormanlisp
      #+digitool :mcl
      #+ecl (or #+ecl-bytecmp :ecl_bytecodes :ecl)
      #+gcl :gcl
      #+lispworks :lispworks
      #+mkcl :mkcl
      #+sbcl :sbcl
      #+scl :scl
      #+xcl :xcl))
(defparameter *early-fasl-directory*
  (make-sub-pathname :directory (relative-dir "fasls" (string-downcase *implementation*))
                     :defaults *build-directory*))

(defun asdf-name (&optional tag)
  (format nil "asdf~@[-~A~]" tag))
(defun asdf-lisp (&optional tag)
  (make-pathname :name (asdf-name tag) :type "lisp" :defaults *build-directory*))
(defun debug-lisp ()
  (make-sub-pathname :directory (relative-dir "contrib") :name "debug" :type "lisp" :defaults *asdf-directory*))
(defun early-compile-file-pathname (file)
  (compile-file-pathname
   (make-pathname :name (pathname-name file) :type "lisp" :defaults *early-fasl-directory*)))
(defun asdf-fasl (&optional tag)
  (early-compile-file-pathname (asdf-lisp tag)))


;;; Test helper functions

(load (debug-lisp))
(verbose t nil)

(defmacro assert-compare (expr)
  (destructuring-bind (op x y) expr
    `(assert-compare-helper ',op ',x ',y ,x ,y)))

(defun assert-compare-helper (op qx qy x y)
  (unless (funcall op x y)
    (error "These two expressions fail comparison with ~S:~%~
            ~S evaluates to ~S~% ~S evaluates to ~S~%"
            op qx x qy y)))

(defmacro assert-equal (x y)
  `(assert-compare (equal ,x ,y)))

(defun touch-file (file &key (offset 0) timestamp)
  (let ((timestamp (or timestamp (+ offset (get-universal-time)))))
    (multiple-value-bind (sec min hr day month year) (decode-universal-time timestamp #+gcl2.6 -5)
      (acall :run-program
             `("touch" "-t" ,(format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D.~2,'0D"
                                     year month day hr min sec)
                       ,(namestring file)))
      (assert-equal (file-write-date file) timestamp))))

(defun hash-table->alist (table)
  (loop :for key :being :the :hash-keys :of table :using (:hash-value value)
    :collect (cons key value)))

(defun exit-lisp (&optional (code 0)) ;; Simplified from asdf/image:quit
  (finish-outputs*)
  #+(or abcl xcl) (ext:quit :status code)
  #+allegro (excl:exit code :quiet t)
  #+clisp (ext:quit code)
  #+clozure (ccl:quit code)
  #+cormanlisp (win32:exitprocess code)
  #+(or cmu scl) (unix:unix-exit code)
  #+ecl (si:quit code)
  #+gcl (lisp:quit code)
  #+genera (error "You probably don't want to Halt the Machine. (code: ~S)" code)
  #+lispworks (lispworks:quit :status code :confirm nil :return nil :ignore-errors-p t)
  #+mcl (ccl:quit) ;; or should we use FFI to call libc's exit(3) ?
  #+mkcl (mk-ext:quit :exit-code code)
  #+sbcl #.(let ((exit (find-symbol "EXIT" :sb-ext))
		 (quit* (find-symbol "QUIT" :sb-ext)))
	     (cond
	       (exit `(,exit :code code :abort t))
	       (quit* `(,quit* :unix-status code :recklessly-p t))))
  #-(or abcl allegro clisp clozure cmu ecl gcl genera lispworks mcl mkcl sbcl scl xcl)
  (error "~S called with exit code ~S but there's no quitting on this implementation" 'quit code))


(defun leave-test (message return)
  (finish-outputs*)
  (fresh-line *error-output*)
  (when message
    (format *error-output* message)
    (fresh-line *error-output*))
  (finish-outputs*)
  (throw :asdf-test-done return))

(defmacro with-test ((&optional) &body body)
  `(call-with-test (lambda () ,@body)))

(defun call-with-test (thunk)
  "Unless the environment variable DEBUG_ASDF_TEST
is bound, write a message and exit on an error.  If
*asdf-test-debug* is true, enter the debugger."
  (redirect-outputs)
  (let ((result
          (catch :asdf-test-done
            (handler-bind
                ((error (lambda (c)
                          (ignore-errors
                           (format *error-output* "~&TEST ABORTED: ~A~&" c))
                          (finish-outputs*)
                          (cond
                            (*debug-asdf*
                             (format t "~&It's your baby, fix it!~%")
                             (break))
                            (t
                             (ignore-errors
                              (acall :print-condition-backtrace
                                     c :count 69 :stream *error-output*))
                             (leave-test "Script failed" 1))))))
              (funcall thunk)
              (leave-test "Script succeeded" 0)))))
    (when *quit-when-done*
      (exit-lisp result))))

;;; These are used by the upgrade tests

(defmacro quietly (&body body)
  `(call-quietly #'(lambda () ,@body)))

(defun call-quietly (thunk)
  (handler-bind (#+sbcl (sb-kernel:redefinition-warning #'muffle-warning))
    (funcall thunk)))

(defun load-asdf-lisp (&optional tag)
  (quietly (load (asdf-lisp tag) :verbose *load-verbose* :print *load-print*)))

(defun load-asdf-fasl (&optional tag)
  (quietly (load (asdf-fasl tag))))

(defun register-directory (dir)
  (pushnew dir (symbol-value (asym :*central-registry*))))

(defun load-asdf-system (&rest keys)
  (quietly
   (register-directory *asdf-directory*)
   (apply (asym :oos) (asym :load-op) :asdf keys)))

(defun call-with-asdf-conditions (thunk &optional verbose)
  (declare (ignorable verbose))
  (handler-bind (#+sbcl
                 ((or sb-c::simple-compiler-note sb-kernel:redefinition-warning)
                   #'muffle-warning)
                 #+(and ecl (not ecl-bytecmp))
                 ((or c::compiler-note c::compiler-debug-note
                      c::compiler-warning) ;; ECL emits more serious warnings than it should.
                   #'muffle-warning)
                 #+mkcl
                 ((or compiler:compiler-note) #'muffle-warning)
                 #-(or cmu scl)
                 ;; style warnings shouldn't abort the compilation [2010/02/03:rpg]
                 (style-warning
                   #'(lambda (w)
                       ;; escalate style-warnings to warnings - we don't want them.
                       (when verbose
                         (warn "Can you please fix ASDF to not emit style-warnings? Got a ~S:~%~A"
                               (type-of w) w))
                       (muffle-warning w))))
    (funcall thunk)))

(defmacro with-asdf-conditions ((&optional verbose) &body body)
  `(call-with-asdf-conditions #'(lambda () ,@body) ,verbose))

(defun compile-asdf (&optional tag verbose)
  (let* ((alisp (asdf-lisp tag))
         (afasl (asdf-fasl tag))
         (tmp (make-pathname :name "asdf-tmp" :defaults afasl)))
    (ensure-directories-exist afasl)
    (multiple-value-bind (result warnings-p errors-p)
        (compile-file alisp :output-file tmp #-gcl :verbose #-gcl verbose :print verbose)
      (flet ((bad (key)
               (when result (ignore-errors (delete-file result)))
               key)
             (good (key)
               (when (probe-file afasl) (delete-file afasl))
               (rename-file tmp afasl)
               key))
        (cond
          (errors-p (bad :errors))
          (warnings-p
           (or
            ;; ECL 11.1.1 has spurious warnings, same with XCL 0.0.0.291.
            ;; SCL has no warning but still raises the warningp flag since 2.20.15 (?)
            #+(or cmu ecl scl xcl) (good :expected-warnings)
          (bad :unexpected-warnings)))
          (t (good :success)))))))

(defun maybe-compile-asdf (&optional tag)
  (let ((alisp (asdf-lisp tag))
        (afasl (asdf-fasl tag)))
    (cond
      ((not (probe-file alisp))
       :not-found)
      ((and (probe-file afasl)
            (> (file-write-date afasl) (file-write-date alisp))
            (ignore-errors (load-asdf-fasl tag)))
       :previously-compiled)
      (t
       (load-asdf-lisp tag)
       (compile-asdf tag)))))

(defun compile-asdf-script ()
  (with-test ()
    #-gcl2.6
    (ecase (with-asdf-conditions () (maybe-compile-asdf))
      (:not-found
       (leave-test "Testsuite failed: unable to find ASDF source" 3))
      (:previously-compiled
       (leave-test "Reusing previously-compiled ASDF" 0))
      (:errors
       (leave-test "Testsuite failed: ASDF compiled with ERRORS" 2))
      (:unexpected-warnings
       (leave-test "Testsuite failed: ASDF compiled with unexpected warnings" 1))
      (:expected-warnings
       (leave-test "ASDF compiled with warnings, ignored for your implementation" 0))
      (:success
       (leave-test "ASDF compiled cleanly" 0)))))

(defun compile-load-asdf (&optional tag)
  ;; emulate the way asdf upgrades itself: load source, compile, load fasl.
  (load-asdf-lisp tag)
  (ecase (compile-asdf tag)
    ((:errors :unexpected-warnings) (leave-test "failed to compile ASDF" 1))
    ((:expected-warnings :success)
     (load-asdf-fasl tag))))

;;; Now, functions to compile and load ASDF.

(defun load-test-system (x &key verbose)
  (let ((*load-print* verbose)
        (*load-verbose* verbose))
    (register-directory *test-directory*)
    (acall :oos (asym :load-op) x :verbose verbose)))

(defun get-asdf-version ()
  (when (find-package :asdf)
    (let ((ver (symbol-value (or (find-symbol (string :*asdf-version*) :asdf)
                                 (find-symbol (string :*asdf-revision*) :asdf)))))
      (typecase ver
        (string ver)
        (cons (format nil "~{~D~^.~}" ver))
        (null "1.0")))))


(defun test-upgrade (old-method new-method tag) ;; called by run-test
  (with-test ()
    (when old-method
      (cond
        ((string-equal tag "REQUIRE")
         (format t "Requiring some previous ASDF ~A~%" tag)
         (ignore-errors (funcall 'require "asdf"))
         (if (member "ASDF" *modules* :test 'equalp)
             (format t "Your Lisp implementation provided ASDF ~A~%" (get-asdf-version))
             (leave-test "Your Lisp implementation does not provide ASDF. Skipping test.~%" 0)))
        (t
         (format t "Loading old asdf ~A via ~A~%" tag old-method)
         (funcall old-method tag))))
    (format t "Now loading new asdf via method ~A~%" new-method)
    (funcall new-method)
    (format t "Testing it~%")
    (register-directory *test-directory*)
    (load-test-system :test-module-depend)
    (assert (eval (intern (symbol-name '#:*file1*) :test-package)))
    (assert (eval (intern (symbol-name '#:*file3*) :test-package)))))

(defun output-location (&rest sublocation)
  (list* *asdf-directory* "build/fasls" :implementation sublocation))
(defun resolve-output (&rest sublocation)
  (acall :resolve-location (apply 'output-location sublocation)))

(defun test-source (file)
  (acall :subpathname *test-directory* file))
(defun test-output-dir ()
  (resolve-output "asdf" "test"))
(defun test-output (file)
  (acall :subpathname (test-output-dir) file))
(defun test-fasl (file)
  (acall :compile-file-pathname* (test-source file)))

(defun clean-asdf-system ()
  (let ((fasl (resolve-output "asdf" "build" "asdf.fasl")))
    (when (DBG :clean fasl (probe-file fasl)) (delete-file fasl))))

(defun load-asdf-lisp-clean ()
  (load-asdf-lisp)
  (clean-asdf-system))

(defun configure-asdf ()
  (setf *debug-asdf* (or *debug-asdf* (acall :getenvp "DEBUG_ASDF_TEST")))
  (untrace)
  (eval `(trace ,@(loop :for s :in *trace-symbols* :collect (asym s))))
  (acall :initialize-source-registry
         `(:source-registry :ignore-inherited-configuration))
  (acall :initialize-output-translations
         `(:output-translations
           ((,*asdf-directory* :**/ :*.*.*) ,(output-location "asdf"))
           (t ,(output-location "root"))
           :ignore-inherited-configuration))
  (set (asym :*central-registry*) `(,*test-directory*))
  (set (asym :*verbose-out*) *standard-output*)
  (set (asym :*asdf-verbose*) t))

(defun load-asdf (&optional tag)
  #+gcl2.6 (load-asdf-lisp tag) #-gcl2.6
  (load-asdf-fasl tag)
  (use-package :asdf :asdf-test)
  (use-package :asdf/driver :asdf-test)
  (configure-asdf)
  (setf *package* (find-package :asdf-test)))

(defun debug-asdf ()
  (setf *debug-asdf* t)
  (setf *quit-when-done* nil)
  (setf *package* (find-package :asdf-test)))

(defun just-load-asdf-fasl () (load-asdf-fasl))

;; Actual scripts rely on this function:
(defun common-lisp-user::load-asdf () (load-asdf))

(setf *package* (find-package :asdf-test))

(defmacro def-test-system (name &rest rest)
  `(apply (asym :register-system-definition) ',name :pathname ,*test-directory*
          :source-file nil ',rest))

(defun in-plan-p (plan x) (member x plan :key (asym :action-path) :test 'equal))

;;; Helpful for debugging

(defun pathname-components (p)
  (when p
    (let ((p (pathname p)))
      (list :host (pathname-host p)
            :device (pathname-device p)
            :directory (pathname-directory p)
            :name (pathname-name p)
            :type (pathname-type p)
            :version (pathname-version p)))))

(defun assert-pathname-equal-helper (qx x qy y)
  (cond
    ((equal x y)
     (format t "~S and ~S both evaluate to same path:~%  ~S~%" qx qy x))
    ((acall :pathname-equal x y)
     (format t "These two expressions yield pathname-equal yet not equal path~%  ~S~%" x)
     (format t "the first expression ~S yields this:~%  ~S~%" qx (pathname-components x))
     (format t "the other expression ~S yields that:~%  ~S~%" qy (pathname-components y)))
    (t
     (format t "These two expressions yield paths that are not pathname-equal~%")
     (format t "the first expression ~S yields this:~%  ~S~%  ~S~%" qx x (pathname-components x))
     (format t "the other expression ~S yields that:~%  ~S~%  ~S~%" qy y (pathname-components y)))))
(defmacro assert-pathname-equal (x y)
  `(assert-pathname-equal-helper ',x ,x ',y ,y))
(defun assert-length-equal-helper (qx qy x y)
  (unless (= (length x) (length y))
    (format t "These two expressions yield sequences of unequal length~%")
    (format t "The first, ~S, has value ~S of length ~S~%" qx x (length x))
    (format t "The other, ~S, has value ~S of length ~S~%" qy y (length y))))
(defun assert-pathnames-equal-helper (qx x qy y)
  (assert-length-equal-helper qx x qy y)
  (loop :for n :from 0
        :for qpx = `(nth ,n ,qx)
        :for qpy = `(nth ,n ,qy)
        :for px :in x
        :for py :in y :do
        (assert-pathname-equal-helper qpx px qpy py)))
(defmacro assert-pathnames-equal (x y)
  `(assert-pathnames-equal-helper ',x ,x ',y ,y))


;; These are shorthands for interactive debugging of test scripts:
(!a
 common-lisp-user::debug-asdf debug-asdf
 da debug-asdf common-lisp-user::da debug-asdf
 la load-asdf common-lisp-user::la load-asdf
 ll load-asdf-lisp
 v verbose)

#| For the record, the following form is sometimes useful to insert in
 asdf/plan:compute-action-stamp to find out what's happening.
 It depends on the DBG macro in contrib/debug.lisp,
 that you should load in your asdf/plan by inserting an (asdf-debug) form in it.

 (let ((action-path (action-path (cons o c)))) (DBG :cas action-path just-done plan stamp-lookup out-files in-files out-op op-time dep-stamp out-stamps in-stamps missing-in missing-out all-present earliest-out latest-in up-to-date-p done-stamp (operation-done-p o c)
;;; blah
))
|#
