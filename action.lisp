;;;; -------------------------------------------------------------------------
;;;; Actions

(asdf/package:define-package :asdf/action
  (:nicknames :asdf-action)
  (:recycle :asdf/action :asdf)
  (:use :uiop/common-lisp :uiop :asdf/upgrade
   :asdf/component :asdf/system #:asdf/cache :asdf/find-system :asdf/find-component :asdf/operation)
  (:export
   #:action #:define-convenience-action-methods
   #:explain #:action-description
   #:downward-operation #:upward-operation #:sideway-operation #:selfward-operation #:non-propagating-operation
   #:component-depends-on
   #:input-files #:output-files #:output-file #:operation-done-p
   #:action-status #:action-stamp #:action-done-p
   #:component-operation-time #:mark-operation-done #:compute-action-stamp
   #:perform #:perform-with-restarts #:retry #:accept
   #:traverse-actions #:traverse-sub-actions #:required-components ;; in plan
   #:action-path #:find-action #:stamp #:done-p))
(in-package :asdf/action)

(eval-when (#-lispworks :compile-toplevel :load-toplevel :execute) ;; LispWorks issues spurious warning
  (deftype action () '(cons operation component)) ;; a step to be performed while building

  (deftype operation-designator ()
    ;; an operation designates itself,
    ;; nil designates a context-dependent current operation, and
    ;; class-name or class designates an instance of the designated class.
    '(or operation null symbol class)))

(with-upgradability ()
  (defgeneric traverse-actions (actions &key &allow-other-keys))
  (defgeneric traverse-sub-actions (operation component &key &allow-other-keys))
  (defgeneric required-components (component &key &allow-other-keys)))

;;;; Reified representation for storage or debugging. Note: dropping original-initargs
(with-upgradability ()
  (defun action-path (action)
    (destructuring-bind (o . c) action (cons (type-of o) (component-find-path c))))
  (defun find-action (path)
    (destructuring-bind (o . c) path (cons (make-operation o) (find-component () c)))))


;;;; Convenience methods
(with-upgradability ()
  (defmacro define-convenience-action-methods
      (function formals &key if-no-operation if-no-component operation-initargs)
    (let* ((rest (gensym "REST"))
           (found (gensym "FOUND"))
           (keyp (equal (last formals) '(&key)))
           (formals-no-key (if keyp (butlast formals) formals))
           (len (length formals-no-key))
           (operation 'operation)
           (component 'component)
           (opix (position operation formals))
           (coix (position component formals))
           (prefix (subseq formals 0 opix))
           (suffix (subseq formals (1+ coix) len))
           (more-args (when keyp `(&rest ,rest &key &allow-other-keys))))
      (assert (and (integerp opix) (integerp coix) (= coix (1+ opix))))
      (flet ((next-method (o c)
               (if keyp
                   `(apply ',function ,@prefix ,o ,c ,@suffix ,rest)
                   `(,function ,@prefix ,o ,c ,@suffix))))
        `(progn
           (defmethod ,function (,@prefix (,operation symbol) component ,@suffix ,@more-args)
             (if ,operation
                 ,(next-method
                   (if operation-initargs ;backward-compatibility with ASDF1's operate. Yuck.
                       `(apply 'make-operation ,operation :original-initargs ,rest ,rest)
                       `(make-operation ,operation))
                   `(or (find-component () ,component) ,if-no-component))
                 ,if-no-operation))
           (defmethod ,function (,@prefix (,operation operation) ,component ,@suffix ,@more-args)
             (if (typep ,component 'component)
                 (error "No defined method for ~S on ~/asdf-action:format-action/"
                        ',function (cons ,operation ,component))
                 (if-let (,found (find-component () ,component))
                    ,(next-method operation found)
                    ,if-no-component))))))))


;;;; self-description
(with-upgradability ()
  (defgeneric action-description (operation component)
    (:documentation "returns a phrase that describes performing this operation
on this component, e.g. \"loading /a/b/c\".
You can put together sentences using this phrase."))
  (defmethod action-description (operation component)
    (format nil (compatfmt "~@<~A on ~A~@:>")
            (type-of operation) component))
  (defgeneric* (explain) (operation component))
  (defmethod explain ((o operation) (c component))
    (asdf-message (compatfmt "~&~@<; ~@;~A~:>~%") (action-description o c)))
  (define-convenience-action-methods explain (operation component))

  (defun format-action (stream action &optional colon-p at-sign-p)
    (assert (null colon-p)) (assert (null at-sign-p))
    (destructuring-bind (operation . component) action
      (princ (action-description operation component) stream))))


;;;; Dependencies
(with-upgradability ()
  (defgeneric* (component-depends-on) (operation component) ;; ASDF4: rename to component-dependencies
    (:documentation
     "Returns a list of dependencies needed by the component to perform
    the operation.  A dependency has one of the following forms:

      (<operation> <component>*), where <operation> is an operation designator
        with respect to FIND-OPERATION in the context of the OPERATION argument,
        and each <component> is a component designator with respect to
        FIND-COMPONENT in the context of the COMPONENT argument,
        and means that the component depends on
        <operation> having been performed on each <component>; or

      (FEATURE <feature>), which means that the component depends
        on the <feature> expression satisfying FEATUREP.
        (This is DEPRECATED -- use :IF-FEATURE instead.)

    Methods specialized on subclasses of existing component types
    should usually append the results of CALL-NEXT-METHOD to the list."))
  (define-convenience-action-methods component-depends-on (operation component))

  (defmethod component-depends-on :around ((o operation) (c component))
    (do-asdf-cache `(component-depends-on ,o ,c)
      (call-next-method)))

  (defmethod component-depends-on ((o operation) (c component))
    (cdr (assoc (type-of o) (component-in-order-to c))))) ; User-specified in-order dependencies


;;;; upward-operation, downward-operation, sideway-operation, selfward-operation
;; These together handle actions that propagate along the component hierarchy or operation universe.
(with-upgradability ()
  (defclass downward-operation (operation)
    ((downward-operation
      :initform nil :reader downward-operation
      :type operation-designator :allocation :class))
    (:documentation "A DOWNWARD-OPERATION's dependencies propagate down the component hierarchy.
I.e., if O is a DOWNWARD-OPERATION and its DOWNWARD-OPERATION slot designates operation D, then
the action (O . M) of O on module M will depends on each of (D . C) for each child C of module M.
The default value for slot DOWNWARD-OPERATION is NIL, which designates the operation O itself.
E.g. in order for a MODULE to be loaded with LOAD-OP (resp. compiled with COMPILE-OP), all the
children of the MODULE must have been loaded with LOAD-OP (resp. compiled with COMPILE-OP."))
  (defmethod component-depends-on ((o downward-operation) (c parent-component))
    `((,(or (downward-operation o) o) ,@(component-children c)) ,@(call-next-method)))

  (defclass upward-operation (operation)
    ((upward-operation
      :initform nil :reader upward-operation
      :type operation-designator :allocation :class))
    (:documentation "An UPWARD-OPERATION has dependencies that propagate up the component hierarchy.
I.e., if O is an instance of UPWARD-OPERATION, and its UPWARD-OPERATION slot designates operation U,
then the action (O . C) of O on a component C that has the parent P will depends on (U . P).
The default value for slot UPWARD-OPERATION is NIL, which designates the operation O itself.
E.g. in order for a COMPONENT to be prepared for loading or compiling with PREPARE-OP, its PARENT
must first be prepared for loading or compiling with PREPARE-OP."))
  ;; For backward-compatibility reasons, a system inherits from module and is a child-component
  ;; so we must guard against this case. ASDF4: remove that.
  (defmethod component-depends-on ((o upward-operation) (c child-component))
    `(,@(if-let (p (component-parent c))
          `((,(or (upward-operation o) o) ,p))) ,@(call-next-method)))

  (defclass sideway-operation (operation)
    ((sideway-operation
      :initform nil :reader sideway-operation
      :type operation-designator :allocation :class))
    (:documentation "A SIDEWAY-OPERATION has dependencies that propagate \"sideway\" to siblings
that a component depends on. I.e. if O is a SIDEWAY-OPERATION, and its SIDEWAY-OPERATION slot
designates operation S (where NIL designates O itself), then the action (O . C) of O on component C
depends on each of (S . D) where D is a declared dependency of C.
E.g. in order for a COMPONENT to be prepared for loading or compiling with PREPARE-OP,
each of its declared dependencies must first be loaded as by LOAD-OP."))
  (defmethod component-depends-on ((o sideway-operation) (c component))
    `((,(or (sideway-operation o) o)
       ,@(loop :for dep :in (component-sideway-dependencies c)
               :collect (resolve-dependency-spec c dep)))
      ,@(call-next-method)))

  (defclass selfward-operation (operation)
    ((selfward-operation
      ;; NB: no :initform -- if an operation depends on others, it must explicitly specify which
      :type (or operation-designator list) :reader selfward-operation :allocation :class))
    (:documentation "A SELFWARD-OPERATION depends on another operation on the same component.
I.e., if O is a SELFWARD-OPERATION, and its SELFWARD-OPERATION designates a list of operations L,
then the action (O . C) of O on component C depends on each (S . C) for S in L.
A operation-designator designates a singleton list of the designated operation;
a list of operation-designators designates the list of designated operations;
NIL is not a valid operation designator in that context.
E.g. before a component may be loaded by LOAD-OP, it must have been compiled by COMPILE-OP."))
  (defmethod component-depends-on ((o selfward-operation) (c component))
    `(,@(loop :for op :in (ensure-list (selfward-operation o))
              :collect `(,op ,c))
      ,@(call-next-method)))

  (defclass non-propagating-operation (operation)
    ()
    (:documentation "A NON-PROPAGATING-OPERATION is an operation that propagates 
no dependencies whatsoever.  It is supplied in order that the programmer be able
to specify that s/he is intentionally specifying an operation which invokes no
dependencies.")))


;;;---------------------------------------------------------------------------
;;; Help programmers catch obsolete OPERATION subclasses
;;;---------------------------------------------------------------------------
(defmethod initialize-instance :before ((obj operation) &key)
  (unless 
      (loop :for x :in '(downward-operation upward-operation sideway-operation
                                            selfward-operation non-propagating-operation
                                            ;; the following is a special case
                                            build-op)
            :when (typep obj x)
            :return t
            :finally (return nil))
    (error "No dependency propagating scheme specified for operation ~a.~
This is likely because the OPERATION subclass of this object has not been ~
updated for ASDF 3." obj)))

(defmethod initialize-instance :before ((obj non-propagating-operation) &key)
  (when
      (loop :for x :in '(downward-operation upward-operation sideway-operation
                                            selfward-operation)
            :when (typep obj x)
            :return t
            :finally (return nil))
    (error "Inconsistent class: ~a No class should have both NON-PROPAGATING-OPERATION and a propagating 
operation class as superclasses." (class-name (class-of obj)))))

;;;---------------------------------------------------------------------------
;;; End of OPERATION class checking
;;;---------------------------------------------------------------------------


;;;; Inputs, Outputs, and invisible dependencies
(with-upgradability ()
  (defgeneric* (output-files) (operation component))
  (defgeneric* (input-files) (operation component))
  (defgeneric* (operation-done-p) (operation component)
    (:documentation "Returns a boolean, which is NIL if the action is forced to be performed again"))
  (define-convenience-action-methods output-files (operation component))
  (define-convenience-action-methods input-files (operation component))
  (define-convenience-action-methods operation-done-p (operation component))

  (defmethod operation-done-p ((o operation) (c component))
    (declare (ignorable o c))
    t)

  (defmethod output-files :around (operation component)
    "Translate output files, unless asked not to. Memoize the result."
    operation component ;; hush genera, not convinced by declare ignorable(!)
    (do-asdf-cache `(output-files ,operation ,component)
      (values
       (multiple-value-bind (pathnames fixedp) (call-next-method)
         ;; 1- Make sure we have absolute pathnames
         (let* ((directory (pathname-directory-pathname
                            (component-pathname (find-component () component))))
                (absolute-pathnames
                  (loop
                    :for pathname :in pathnames
                    :collect (ensure-absolute-pathname pathname directory))))
           ;; 2- Translate those pathnames as required
           (if fixedp
               absolute-pathnames
               (mapcar *output-translation-function* absolute-pathnames))))
       t)))
  (defmethod output-files ((o operation) (c component))
    (declare (ignorable o c))
    nil)
  (defun output-file (operation component)
    "The unique output file of performing OPERATION on COMPONENT"
    (let ((files (output-files operation component)))
      (assert (length=n-p files 1))
      (first files)))

  (defmethod input-files :around (operation component)
    "memoize input files."
    (do-asdf-cache `(input-files ,operation ,component)
      (call-next-method)))

  (defmethod input-files ((o operation) (c component))
    (declare (ignorable o c))
    nil)

  (defmethod input-files ((o selfward-operation) (c component))
    `(,@(or (loop :for dep-o :in (ensure-list (selfward-operation o))
                  :append (or (output-files dep-o c) (input-files dep-o c)))
            (if-let ((pathname (component-pathname c)))
              (and (file-pathname-p pathname) (list pathname))))
      ,@(call-next-method))))


;;;; Done performing
(with-upgradability ()
  (defgeneric component-operation-time (operation component)) ;; ASDF4: hide it behind plan-action-stamp
  (define-convenience-action-methods component-operation-time (operation component))

  (defgeneric mark-operation-done (operation component)) ;; ASDF4: hide it behind (setf plan-action-stamp)
  (defgeneric compute-action-stamp (plan operation component &key just-done)
    (:documentation "Has this action been successfully done already,
and at what known timestamp has it been done at or will it be done at?
Takes two keywords JUST-DONE and PLAN:
JUST-DONE is a boolean that is true if the action was just successfully performed,
at which point we want compute the actual stamp and warn if files are missing;
otherwise we are making plans, anticipating the effects of the action.
PLAN is a plan object modelling future effects of actions,
or NIL to denote what actually happened.
Returns two values:
* a STAMP saying when it was done or will be done,
  or T if the action has involves files that need to be recomputed.
* a boolean DONE-P that indicates whether the action has actually been done,
  and both its output-files and its in-image side-effects are up to date."))

  (defclass action-status ()
    ((stamp
      :initarg :stamp :reader action-stamp
      :documentation "STAMP associated with the ACTION if it has been completed already
in some previous image, or T if it needs to be done.")
     (done-p
      :initarg :done-p :reader action-done-p
      :documentation "a boolean, true iff the action was already done (before any planned action)."))
    (:documentation "Status of an action"))

  (defmethod print-object ((status action-status) stream)
    (print-unreadable-object (status stream :type t)
      (with-slots (stamp done-p) status
        (format stream "~@{~S~^ ~}" :stamp stamp :done-p done-p))))

  (defmethod component-operation-time ((o operation) (c component))
    (gethash (type-of o) (component-operation-times c)))

  (defmethod mark-operation-done ((o operation) (c component))
    (setf (gethash (type-of o) (component-operation-times c))
          (compute-action-stamp nil o c :just-done t))))


;;;; Perform
(with-upgradability ()
  (defgeneric* (perform-with-restarts) (operation component))
  (defgeneric* (perform) (operation component))
  (define-convenience-action-methods perform (operation component))

  (defmethod perform :before ((o operation) (c component))
    (ensure-all-directories-exist (output-files o c)))
  (defmethod perform :after ((o operation) (c component))
    (mark-operation-done o c))
  (defmethod perform ((o operation) (c parent-component))
    (declare (ignorable o c))
    nil)
  (defmethod perform ((o operation) (c source-file))
    (sysdef-error
     (compatfmt "~@<Required method PERFORM not implemented for operation ~A, component ~A~@:>")
     (class-of o) (class-of c)))

  (defmethod perform-with-restarts (operation component)
    ;; TOO verbose, especially as the default. Add your own :before method
    ;; to perform-with-restart or perform if you want that:
    #|(explain operation component)|#
    (perform operation component))
  (defmethod perform-with-restarts :around (operation component)
    (loop
      (restart-case
          (return (call-next-method))
        (retry ()
          :report
          (lambda (s)
            (format s (compatfmt "~@<Retry ~A.~@:>")
                    (action-description operation component))))
        (accept ()
          :report
          (lambda (s)
            (format s (compatfmt "~@<Continue, treating ~A as having been successful.~@:>")
                    (action-description operation component)))
          (mark-operation-done operation component)
          (return))))))

;;; Generic build operation
(with-upgradability ()
  (defmethod component-depends-on ((o build-op) (c component))
    `((,(or (component-build-operation c) 'load-op) ,c))))

