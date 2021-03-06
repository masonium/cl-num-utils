(in-package :cl-num-utils-tests)

;; TEST SUITES

(deftestsuite cl-num-utils-tests () ())

;; EXTERNAL

(defun run-cl-num-utils-tests ()
  "Run all the tests for CL-NUM-UTILS."
  (run-tests :suite 'cl-num-utils-tests))

;;; utilities

(defun ia* (start &rest dimensions)
  "Return an array with given dimensions, filled with integers from START,
in row-major order.  For testing purposes."
  (aprog1 (make-array dimensions)
    (iter
      (for i :from 0 :below (array-total-size it))
      (for value :from start)
      (setf (row-major-aref it i) value))))

(defun ia (&rest dimensions)
  "Return an array with given dimensions, filled with integers from 0,
in row-major order.  For testing purposes."
  (apply #'ia* 0 dimensions))

