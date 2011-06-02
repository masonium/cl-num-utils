;;; -*- Mode:Lisp; Syntax:ANSI-Common-Lisp; Coding:utf-8 -*-

(in-package #:cl-num-utils)

;;; utility functions

(defmacro define-vector-accessors (&optional (n 10))
  (flet ((accessor-name (i)
           (intern (format nil "~:@(~:r~)*" i))))
    `(progn
       ,@(loop for i from 1 to n
               collect 
               `(defun ,(accessor-name i) (array)
                  (row-major-aref array ,(1- i))))
       (declaim (inline ,@(loop for i from 1 to n
                                collect (accessor-name i)))))))

(define-vector-accessors)

(defmacro row-major-loop ((dimensions row-major-index row-index col-index
                                      &key (nrow (gensym* '#:nrow))
                                           (ncol (gensym* '#:ncol)))
                          &body body)
  "Loop through row-major matrix with given DIMENSIONS, incrementing
ROW-MAJOR-INDEX, ROW-INDEX and COL-INDEX."
  (check-types (row-index col-index row-major-index nrow ncol) symbol)
  `(let+ (((,nrow ,ncol) ,dimensions)
          (,row-major-index 0))
     (dotimes (,row-index ,nrow)
       (dotimes (,col-index ,ncol)
         ,@body
         (incf ,row-major-index)))))

(defun array-element-type-available (type)
  "Return a boolean indicating whether TYPE upgraded to itself for arrays.
  Naturally, the result is implementation-dependent and constant within the
  same implementation."
  (type= (upgraded-array-element-type type) type))

(defun displace-array (array dimensions &optional (offset 0))
  "Shorthand function for displacing an array."
  (make-array dimensions
              :displaced-to array
              :displaced-index-offset offset
              :element-type (array-element-type array)))

(defun make-similar-array (array 
                           &key (dimensions (array-dimensions array))
                                (initial-element nil initial-element?))
  "Make a simple-array with the given dimensions and element-type
similar to array."
  (let ((element-type (array-element-type array)))
    (if initial-element?
        (make-array dimensions :element-type element-type
                    :initial-element (coerce initial-element element-type))
        (make-array dimensions :element-type element-type))))

(defun filled-array (dimensions function &optional (element-type t))
  "Create array with given DIMENSIONS and ELEMENT-TYPE, then fill by calling
FUNCTION, traversing in row-major order."
  (aprog1 (make-array dimensions :element-type element-type)
    (dotimes (index (array-total-size it))
      (setf (row-major-aref it index) (funcall function)))))

(defmethod rep (vector times &optional (each 1))
  "Return a new sequence, which contains SEQUENCE repeated TIMES times,
repeating each element EACH times (default is 1)."
  (let* ((n (length vector))
         (result (make-similar-array vector :dimensions (* n times each)))
         (result-index 0))
    (dotimes (outer times)
      (dotimes (vector-index n)
        (let ((elt (aref vector vector-index)))
          (dotimes (inner each)
            (setf (aref result result-index) elt)
            (incf result-index)))))
    result))

;;; reshape

(defun fill-in-dimensions (dimensions size)
  "If one of the dimensions is missing (indicated with T), replace it with a
dimension so that the total product equals SIZE.  If that's not possible,
signal an error.  If there are no missing dimensions, just check that the
product equals size."
  (let+ ((dimensions (ensure-list dimensions))
         ((&flet missing? (dimension) (eq dimension t)))
         missing
         (product 1))
    (mapc (lambda (dimension)
            (if (missing? dimension) 
                (progn
                  (assert (not missing) () "More than one missing dimension.")
                  (setf missing t))
                (progn
                  (check-type dimension (integer 1))
                  (multf product dimension))))
          dimensions)
    (if missing
        (let+ (((&values fraction remainder) (floor size product)))
          (assert (zerop remainder) ()
                  "Substitution does not result in an integer.")
          (mapcar (lambda (dimension)
                    (if (missing? dimension) fraction dimension))
                  dimensions))
        dimensions)))

(defun reshape (array dimensions &key (offset 0) copy?)
  (let* ((size (array-total-size array))
         (dimensions (fill-in-dimensions dimensions (- size offset))))
    (maybe-copy-array (displace-array array dimensions offset) copy?)))

(defun flatten-array (array &key copy?)
  "Return ARRAY flattened to a vector.  WillMay share structure unless COPY?."
  (let ((vector (displace-array array (array-total-size array))))
    (if copy? (copy-seq vector) vector)))

;;; subarrays 

(defun subarrays (array rank)
  "Return an array of subarrays, split of at RANK.  All subarrays are
displaced and share structure."
  (let ((array-rank (array-rank array)))
    (cond
      ((or (zerop rank) (= rank array-rank))
       array)
      ((< 0 rank array-rank)
       (let* ((dimensions (array-dimensions array))
              (result 
               (make-similar-array array
                                   :dimensions (subseq dimensions 0 rank)))
              (sub-dimensions (subseq dimensions rank))
              (sub-size (product sub-dimensions)))
         (dotimes (index (array-total-size result))
           (setf (row-major-aref result index)
                 (displace-array array sub-dimensions
                                 (* index sub-size))))
         result))
      (t (error "Rank ~A outside [0,~A]." rank array-rank)))))

(defun subarray (array &rest subscripts)
  "Given a partial list of subscripts, return the subarray that starts there,
with all the other subscripts set to 0, dimensions inferred from the original.
If no subscripts are given, the original array is returned.  Implemented by
discplacing, shares structure."
  (let* ((rank (array-rank array))
         (drop (length subscripts)))
    (assert (<= 0 drop rank))
    (cond
      ((zerop drop) array)
      ((< drop rank)
       (displace-array array
                       (subseq (array-dimensions array) drop)
                       (apply #'array-row-major-index array
                              (aprog1 (make-list rank :initial-element 0)
                                (replace it subscripts)))))
      (t (apply #'aref array subscripts)))))

(defun (setf subarray) (value array &rest subscripts)
  (let ((subarray (apply #'subarray array subscripts)))
    (assert (common-dimensions value subarray))
    (replace (flatten-array subarray) (flatten-array value))))

(defun combine (array &optional element-type)
  "The opposite of SUBARRAYS.  If ELEMENT-TYPE is not given, it is inferred
from the first element of array, which also determines the dimensions.  If
that element is not an array, the original ARRAY is returned as it is."
  (let ((first (first* array)))
    (if (arrayp first)
        (let* ((dimensions (array-dimensions array))
               (sub-dimensions (array-dimensions first))
               (element-type (aif element-type it (array-element-type first)))
               (result (make-array (append dimensions sub-dimensions)
                                   :element-type element-type))
               (length (product dimensions))
               (displaced (displace-array result
                                          (cons length sub-dimensions))))
          (dotimes (index length)
            (setf (subarray displaced index) (row-major-aref array index)))
          result)
        array)))

(defgeneric map1 (function object &key element-type &allow-other-keys)
  (:documentation "Map OBJECT elementwise using FUNCTION.  Results in a
  similar object, with specificed ELEMENT-TYPE where applicable.")
  (:method (function (array array) &key (element-type t))
    (aprog1 (make-array (array-dimensions array) :element-type element-type)
      (map-into (flatten-array it) function (flatten-array array))))
  (:method (function (list list) &key)
    (mapcar function list)))

(defun map-subarrays (function array rank &optional element-type)
  "Map subarrays.  When ELEMENT-TYPE is given, it is used for the element type
of the result."
  (combine (map1 function (subarrays array rank)) element-type))

;;; generic interface for array-like objects

(defgeneric as-array (object &key copy?)
  (:documentation "Return OBJECT as an array.  May share structure.")
  (:method ((array array) &key copy?)
    (maybe-copy-array array copy?)))

(defgeneric diagonal (object &key copy?)
  (:documentation "Return diagonal of object.")
  (:method ((matrix array) &key copy?)
    (declare (ignore copy?))
    (let+ (((nrow ncol) (array-dimensions matrix))
           (n (min nrow ncol))
           (diagonal (make-similar-array matrix :dimensions n)))
      (dotimes (i n)
        (setf (row-major-aref diagonal i)
              (aref matrix i i)))
      diagonal)))

(defgeneric transpose (object &key copy?)
  (:documentation "Transpose a matrix.")
  (:method ((matrix array) &key copy?)
    (declare (ignore copy?))
    (let+ (((nrow ncol) (array-dimensions matrix))
           (result (make-array (list ncol nrow)
                               :element-type (array-element-type matrix)))
           (result-index 0))
      (dotimes (col ncol)
        (dotimes (row nrow)
          (setf (row-major-aref result result-index) (aref matrix row col))
          (incf result-index)))
      result)))

(defgeneric transpose* (object &key copy?)
  (:documentation "Conjugate transpose a matrix.")
  (:method ((matrix array) &key copy?)
    (declare (ignore copy?))
    (let+ (((nrow ncol) (array-dimensions matrix))
           (result (make-array (list ncol nrow)
                               :element-type (array-element-type matrix)))
           (result-index 0))
      (dotimes (col ncol)
        (dotimes (row nrow)
          (setf (row-major-aref result result-index)
                (conjugate (aref matrix row col)))
          (incf result-index)))
      result)))

(defun as-row (vector &key copy?)
  "Return vector as a matrix with one row."
  (check-type vector vector)
  (maybe-copy-array (displace-array vector (list 1 (length vector))) copy?))

(defun as-column (vector &key copy?)
  "Return vector as a matrix with one column."
  (check-type vector vector)
  (maybe-copy-array (displace-array vector (list (length vector) 1)) copy?))

;;;; dot product

(defgeneric dot (a b)
  (:documentation "Dot product."))

(defun sum-of-conjugate-squares (vector)
  (reduce #'+ vector :key (lambda (x) (* x (conjugate x)))))

(defmethod dot ((a vector) (b (eql t)))
  (sum-of-conjugate-squares a))

(defmethod dot ((a (eql t)) (b vector))
  (sum-of-conjugate-squares b))

(defmethod dot ((a vector) (b vector))
  (check-types (a b) vector)
  (let ((n (length a)))
    (assert (= n (length b)))
    (iter
      (for a-elt :in-vector a)
      (for b-elt :in-vector b)
      (summing (* (conjugate a-elt) b-elt)))))

;;; outer product

(defun outer (a b &key (function #'*) (element-type t))
  "Generalized outer product of A and B, using FUNCTION.  If either one is T,
it is replaced by the other one.  ELEMENT-TYPE can be used to give the element
type."
  (cond
    ((and (eq t a) (eq t b)) (error "A and B can't both be T!"))
    ((eq t a) (setf a b))
    ((eq t b) (setf b a)))
  (check-types (a b) vector)
  (let* ((a-length (length a))
         (b-length (length b))
         (result (make-array (list a-length b-length) :element-type element-type))
         (result-index 0))
    (iter
      (for a-element :in-vector a)
      (iter
        (for b-element :in-vector b)
        (setf (row-major-aref result result-index)
              (funcall function a-element b-element))
        (incf result-index)))
    result))

;;; norms

;;; !! matrix norms would be nice, in that case we need to make these generic
;;; !! functions.

(defun norm1 (a)
  (reduce #'+ a :key #'abs))

(defun norm2 (a)
  "L2 norm."
  (sqrt (sum-of-conjugate-squares a)))

(defun normsup (a)
  (reduce #'max a :key #'abs))

